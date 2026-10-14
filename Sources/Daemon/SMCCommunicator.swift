import Foundation
import IOKit
import os

struct SMCKeyInfo: Equatable {
    let key: FourCharCode
    let dataSize: UInt32
    let dataType: FourCharCode
    let dataAttributes: UInt8
}

struct SMCPowerKey {
    let info: SMCKeyInfo
    let onBytes: [UInt8]
    let offBytes: [UInt8]
}

private func fourCharCode(_ string: String) -> FourCharCode {
    let bytes = Array(string.utf8)
    precondition(bytes.count == 4)
    return FourCharCode(bytes[0]) << 24
        | FourCharCode(bytes[1]) << 16
        | FourCharCode(bytes[2]) << 8
        | FourCharCode(bytes[3])
}

final class SMCCommunicator {
    private var connection: io_connect_t = IO_OBJECT_NULL

    init() throws {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("AppleSMC")
        )
        guard service != IO_OBJECT_NULL else {
            throw NSError(domain: "SMCCommunicator", code: Int(kIOReturnNotFound))
        }

        var newConnection: io_connect_t = IO_OBJECT_NULL
        let result = IOServiceOpen(
            service,
            mach_task_self_,
            1,
            &newConnection
        )
        guard result == kIOReturnSuccess, newConnection != IO_OBJECT_NULL else {
            IOObjectRelease(service)
            throw NSError(domain: "SMCCommunicator", code: Int(result))
        }

        connection = newConnection
        IOObjectRelease(service)
        _ = IOConnectCallMethod(
            connection,
            UInt32(kSMCUserClientOpen),
            nil,
            0,
            nil,
            0,
            nil,
            nil,
            nil,
            nil
        )
    }

    deinit {
        if connection != IO_OBJECT_NULL {
            _ = IOConnectCallMethod(
                connection,
                UInt32(kSMCUserClientClose),
                nil,
                0,
                nil,
                0,
                nil,
                nil,
                nil,
                nil
            )
            IOServiceClose(connection)
        }
    }

    private var keyInfoCache = [FourCharCode: SMCKeyInfo]()

    func keyInfo(forKey key: FourCharCode) -> SMCKeyInfo? {
        if let cached = keyInfoCache[key] {
            return cached
        }
        var input = SMCParamStruct()
        input.key = key
        input.data8 = UInt8(kSMCGetKeyInfo)

        guard let output = call(&input) else { return nil }
        let info = SMCKeyInfo(
            key: key,
            dataSize: output.keyInfo.dataSize,
            dataType: output.keyInfo.dataType,
            dataAttributes: output.keyInfo.dataAttributes
        )
        keyInfoCache[key] = info
        return info
    }

    func isSupported(_ info: SMCKeyInfo) -> Bool {
        keyInfo(forKey: info.key) == info
    }

    func isKeyAvailable(key: FourCharCode, size: UInt32) -> Bool {
        guard let info = keyInfo(forKey: key) else { return false }
        return info.dataSize == size
    }

    func read(forKey key: FourCharCode, size: Int) -> [UInt8]? {
        var input = SMCParamStruct()
        input.key = key
        input.keyInfo.dataSize = UInt32(size)
        input.data8 = UInt8(kSMCReadKey)

        guard let output = call(&input) else { return nil }
        return withUnsafeBytes(of: output.bytes) { raw in
            Array(raw.prefix(size))
        }
    }

    func write(_ bytes: [UInt8], forKey key: FourCharCode) -> Bool {
        var input = SMCParamStruct()
        input.key = key
        input.keyInfo.dataSize = UInt32(bytes.count)
        input.data8 = UInt8(kSMCWriteKey)
        withUnsafeMutablePointer(to: &input.bytes) { destination in
            bytes.withUnsafeBufferPointer { source in
                if let baseAddress = source.baseAddress {
                    memcpy(destination, baseAddress, bytes.count)
                }
            }
        }

        let output = call(&input)
        let readback = read(forKey: key, size: bytes.count)
        return readback == bytes || (readback == nil && output != nil)
    }

    private func call(_ input: inout SMCParamStruct) -> SMCParamStruct? {
        var output = SMCParamStruct()
        var outputSize = MemoryLayout<SMCParamStruct>.stride
        let result = IOConnectCallStructMethod(
            connection,
            UInt32(kSMCHandleYPCEvent),
            &input,
            MemoryLayout<SMCParamStruct>.stride,
            &output,
            &outputSize
        )
        guard result == kIOReturnSuccess, output.result == UInt8(kSMCSuccess) else {
            os_log("SMC call failed: IOReturn=%{public}d SMC=%{public}d", result, output.result)
            return nil
        }
        return output
    }
}

enum SMCPowerKeys {
    static let chargeKeys = [
        SMCPowerKey(
            info: SMCKeyInfo(
                key: fourCharCode("CHTE"),
                dataSize: 4,
                dataType: fourCharCode("ui32"),
                dataAttributes: 0xD4
            ),
            onBytes: [0, 0, 0, 0],
            offBytes: [1, 0, 0, 0]
        ),
        SMCPowerKey(
            info: SMCKeyInfo(
                key: fourCharCode("CH0C"),
                dataSize: 1,
                dataType: fourCharCode("hex_"),
                dataAttributes: 0xD4
            ),
            onBytes: [0],
            offBytes: [1]
        ),
        SMCPowerKey(
            info: SMCKeyInfo(
                key: fourCharCode("CH0B"),
                dataSize: 1,
                dataType: fourCharCode("ui8 "),
                dataAttributes: 0xD4
            ),
            onBytes: [0],
            offBytes: [2]
        )
    ]

    static let goldenGateUpperKey = SMCKeyInfo(
        key: fourCharCode("bfD0"),
        dataSize: 4,
        dataType: fourCharCode("ui32"),
        dataAttributes: 0xD4
    )

    static let goldenGateLowerKey = SMCKeyInfo(
        key: fourCharCode("bfE0"),
        dataSize: 4,
        dataType: fourCharCode("ui32"),
        dataAttributes: 0xD4
    )

    static let goldenGateCommitKey = SMCKeyInfo(
        key: fourCharCode("bfF0"),
        dataSize: 1,
        dataType: fourCharCode("ui8 "),
        dataAttributes: 0xD4
    )

    static let intelToggleKeys = [
        SMCPowerKey(
            info: SMCKeyInfo(
                key: fourCharCode("CH0B"),
                dataSize: 1,
                dataType: fourCharCode("ui8 "),
                dataAttributes: 0xD4
            ),
            onBytes: [0],
            offBytes: [2]
        ),
        SMCPowerKey(
            info: SMCKeyInfo(
                key: fourCharCode("CH0C"),
                dataSize: 1,
                dataType: fourCharCode("ui8 "),
                dataAttributes: 0xD4
            ),
            onBytes: [0],
            offBytes: [2]
        )
    ]

    static let bclmKey = SMCKeyInfo(
        key: fourCharCode("BCLM"),
        dataSize: 1,
        dataType: fourCharCode("ui8 "),
        dataAttributes: 0xD4
    )

    static let bfclKey = SMCKeyInfo(
        key: fourCharCode("BFCL"),
        dataSize: 1,
        dataType: fourCharCode("ui8 "),
        dataAttributes: 0xD4
    )

    static let adapterKeys = [
        SMCPowerKey(
            info: SMCKeyInfo(
                key: fourCharCode("CHIE"),
                dataSize: 1,
                dataType: fourCharCode("hex_"),
                dataAttributes: 0xD4
            ),
            onBytes: [0],
            offBytes: [8]
        ),
        SMCPowerKey(
            info: SMCKeyInfo(
                key: fourCharCode("CH0J"),
                dataSize: 1,
                dataType: fourCharCode("ui8 "),
                dataAttributes: 0xD4
            ),
            onBytes: [0],
            offBytes: [0x20]
        )
    ]
}
