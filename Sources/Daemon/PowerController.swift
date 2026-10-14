import Foundation
import IOKit.pwr_mgt
import IOKit.ps
import os

final class PowerController {
    struct StoredSettings: Codable {
        var minCharge = 60
        var maxCharge = 80
        var mode = ChargeMode.normal.rawValue
    }

    enum ChargeBackend {
        case appleSilicon(key: SMCPowerKey)
        case goldenGate
        case intelToggle(keys: [SMCPowerKey])
        case intelBCLM

        var name: String {
            switch self {
            case .appleSilicon: return "Apple Silicon CHTE/CH0C"
            case .goldenGate: return "Apple Silicon Golden Gate bfD0/bfE0/bfF0"
            case .intelToggle: return "Intel CH0B/CH0C"
            case .intelBCLM: return "Intel BCLM/BFCL"
            }
        }
    }

    private let queue = DispatchQueue(label: "com.nvksie.chargelmt.power-controller")
    private let smc: SMCCommunicator
    private let chargeBackend: ChargeBackend
    private let adapterKey: SMCPowerKey?
    private let settingsURL = URL(
        fileURLWithPath: "/Library/Application Support/ChargeLmt/settings.plist"
    )
    private var timer: Timer?
    private var powerSourceRunLoopSource: CFRunLoopSource?
    private var sleepAssertion: IOPMAssertionID = 0
    private var chargingDisabled = false
    private var adapterDisabled = false
    private var isActivelyCharging = false
    private var lastAdapterConnected = false
    private var lastWrittenBCLM: Int?
    private var lastToggleEnabled: Bool?
    private var lastGoldenGateUpper: Int?
    private var lastGoldenGateLower: Int?
    private var lastAppleSiliconEnabled: Bool?
    private var lastError: String?
    private var settings: StoredSettings

    init?() {
        guard let smc = try? SMCCommunicator(),
              let chargeBackend = PowerController.detectChargeBackend(
                  smc: smc,
                  architecture: PowerController.hardwareArchitecture
              )
        else { return nil }

        self.smc = smc
        self.chargeBackend = chargeBackend
        self.adapterKey = SMCPowerKeys.adapterKeys.first {
            smc.isKeyAvailable(key: $0.info.key, size: $0.info.dataSize)
        }
        self.settings = PowerController.readStoredSettings()

        if let initialBattery = BatteryMonitor.read() {
            lastAdapterConnected = initialBattery.isAdapterConnected
            if initialBattery.isAdapterConnected {
                // 刚启动时如果电量在区间内则写入下限不充电：
                // 只有电量 <= 下限时才开启主动充电，否则置为 false 并在随后的 evaluate 中写入下限停充
                isActivelyCharging = initialBattery.percent <= settings.minCharge
            } else {
                isActivelyCharging = false
            }
        } else {
            lastAdapterConnected = false
            isActivelyCharging = false
        }

        chargingDisabled = !isActivelyCharging
        if let adapterKey {
            adapterDisabled = !array(
                smc.read(forKey: adapterKey.info.key, size: adapterKey.onBytes.count),
                equals: adapterKey.onBytes
            )
        } else {
            adapterDisabled = false
        }

        // 刚启动时强制进行一次评估，如果电量在区间内则立即写入下限以确保不充电
        queue.async { self.evaluateLocked(force: true) }

        let runLoopSource = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let controller = Unmanaged<PowerController>.fromOpaque(context).takeUnretainedValue()
            controller.queue.async { controller.evaluate() }
        }, Unmanaged.passUnretained(self).toOpaque())

        if let source = runLoopSource?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            self.powerSourceRunLoopSource = source
        }

        let timer = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
            self?.queue.async { self?.evaluate() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func status() -> NSDictionary {
        let result = queue.sync {
            let battery = BatteryMonitor.read()
            return [
                "supported": true,
                "minCharge": settings.minCharge,
                "maxCharge": settings.maxCharge,
                "mode": settings.mode,
                "percent": battery?.percent ?? -1,
                "charging": battery?.isCharging ?? false,
                "adapterConnected": battery?.isAdapterConnected ?? false,
                "chargingDisabled": chargingDisabled,
                "adapterDisabled": adapterDisabled,
                "backend": chargeBackend.name,
                "supportsDischarge": adapterKey != nil,
                "error": lastError ?? ""
            ]
        }
        return result as NSDictionary
    }

    func setLimits(minCharge: Int, maxCharge: Int) -> Bool {
        queue.sync {
            guard ChargeLimits.isValid(minCharge: minCharge, maxCharge: maxCharge) else {
                return false
            }
            settings.minCharge = minCharge
            settings.maxCharge = maxCharge
            persistSettings()

            // 低于下限时准备充电，高于下限时进入航海/不充电阶段
            let currentPercent: Int
            if let battery = BatteryMonitor.read() {
                currentPercent = battery.percent
                isActivelyCharging = battery.percent <= minCharge
            } else {
                currentPercent = -1
                isActivelyCharging = false
            }
            os_log(
                "setLimits: min=%{public}d max=%{public}d, battery=%{public}d%%, isActivelyCharging=%{public}d",
                minCharge,
                maxCharge,
                currentPercent,
                isActivelyCharging ? 1 : 0
            )

            evaluateLocked(force: true)
            return lastError == nil
        }
    }

    func setMode(_ rawMode: String) -> Bool {
        queue.sync {
            guard let mode = ChargeMode(rawValue: rawMode) else { return false }
            if mode == .dischargeToLimit && adapterKey == nil {
                lastError = "此机型不支持在不拔电源的情况下强制放电"
                return false
            }
            settings.mode = mode.rawValue
            persistSettings()
            evaluateLocked(force: true)
            return lastError == nil
        }
    }

    func shutdown() {
        queue.sync {
            if let source = powerSourceRunLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
                powerSourceRunLoopSource = nil
            }
            timer?.invalidate()
            timer = nil
            _ = setChargingEnabled(true, targetLimit: 100, force: true)
            _ = setAdapterEnabled(true)
            releaseSleepAssertion()
        }
    }

    private func evaluate() {
        queue.async { self.evaluateLocked() }
    }

    private func evaluateLocked(force: Bool = false) {
        guard let battery = BatteryMonitor.read() else {
            lastError = "无法读取电池状态"
            return
        }

        lastError = nil
        switch ChargeMode(rawValue: settings.mode) ?? .normal {
        case .normal:
            controlNormal(battery, force: force)
        case .chargeFull:
            controlFullCharge(battery, force: force)
        case .dischargeToLimit:
            controlDischarge(battery, force: force)
        }
    }

    private func controlNormal(_ battery: BatterySnapshot, force: Bool = false) {
        if adapterDisabled {
            _ = setAdapterEnabled(true)
            acquireSleepAssertion()
        }

        let adapterJustConnected = battery.isAdapterConnected && !lastAdapterConnected
        lastAdapterConnected = battery.isAdapterConnected

        if battery.isAdapterConnected {
            if adapterJustConnected && battery.percent > settings.minCharge {
                // 插上适配器且电量高于下限时，不充电，写入下限保持航海
                isActivelyCharging = false
            } else if battery.percent >= settings.maxCharge {
                // 达到上限后停止充电，写入下限避免反复小区间充电
                isActivelyCharging = false
            } else if battery.percent <= settings.minCharge {
                // 低于下限时写入上限开始充电
                isActivelyCharging = true
            }

            let shouldForce = force || adapterJustConnected
            if isActivelyCharging {
                // 低于下限时写入上限开始充电
                if !setChargingEnabled(true, targetLimit: settings.maxCharge, battery: battery, force: shouldForce) {
                    lastError = "无法恢复充电"
                    return
                }
                acquireSleepAssertion()
            } else {
                // 达到上限后写入下限避免反复小区间充电
                if !setChargingEnabled(false, targetLimit: settings.minCharge, battery: battery, force: shouldForce) {
                    lastError = "无法停止充电"
                    return
                }
                releaseSleepAssertion()
            }
        } else {
            // 电池供电状态：写入下限保持状态
            isActivelyCharging = false
            _ = setChargingEnabled(false, targetLimit: settings.minCharge, battery: battery, force: force)
            releaseSleepAssertion()
        }
    }

    private func controlFullCharge(_ battery: BatterySnapshot, force: Bool = false) {
        guard setAdapterEnabled(true) else {
            lastError = "无法恢复电源适配器"
            return
        }

        if battery.percent >= 100 {
            settings.mode = ChargeMode.normal.rawValue
            persistSettings()
            isActivelyCharging = false
            _ = setChargingEnabled(false, targetLimit: settings.minCharge, battery: battery, force: true)
            releaseSleepAssertion()
            return
        }

        guard setChargingEnabled(true, targetLimit: 100, battery: battery, force: force) else {
            lastError = "无法启动充电"
            return
        }
        isActivelyCharging = true
        acquireSleepAssertion()
    }

    private func controlDischarge(_ battery: BatterySnapshot, force: Bool = false) {
        if battery.percent <= settings.maxCharge {
            settings.mode = ChargeMode.normal.rawValue
            persistSettings()
            _ = setAdapterEnabled(true)
            isActivelyCharging = false
            _ = setChargingEnabled(false, targetLimit: settings.minCharge, battery: battery, force: true)
            releaseSleepAssertion()
            return
        }

        guard setAdapterEnabled(false), setChargingEnabled(false, targetLimit: settings.minCharge, battery: battery, force: force) else {
            lastError = "无法启动放电"
            return
        }
        isActivelyCharging = false
        acquireSleepAssertion()
    }

    private func setChargingEnabled(
        _ enabled: Bool,
        targetLimit: Int? = nil,
        battery: BatterySnapshot? = nil,
        force: Bool = false
    ) -> Bool {
        let success: Bool
        switch chargeBackend {
        case .appleSilicon(let key):
            if !force && lastAppleSiliconEnabled == enabled && chargingDisabled == !enabled {
                return true
            }
            let bytes = enabled ? key.onBytes : key.offBytes
            success = smc.write(bytes, forKey: key.info.key)
            if success {
                lastAppleSiliconEnabled = enabled
            }

        case .goldenGate:
            let upper: Int
            let lower: Int
            if enabled {
                upper = targetLimit ?? settings.maxCharge
                lower = settings.minCharge
            } else {
                upper = targetLimit ?? settings.minCharge
                lower = max(ChargeLimits.minimum, upper - 1)
            }
            if !force && lastGoldenGateUpper == upper && lastGoldenGateLower == lower && chargingDisabled == !enabled {
                return true
            }
            success = setGoldenGateLimits(upper: upper, lower: lower)
            if success {
                lastGoldenGateUpper = upper
                lastGoldenGateLower = lower
            }

        case .intelToggle(let keys):
            if !force && lastToggleEnabled == enabled && chargingDisabled == !enabled {
                return true
            }
            success = !keys.isEmpty && keys.allSatisfy { key in
                let bytes = enabled ? key.onBytes : key.offBytes
                return smc.write(bytes, forKey: key.info.key)
            }
            if success {
                lastToggleEnabled = enabled
            }

        case .intelBCLM:
            // 低于下限时写入上限开始充电，达到上限后写入下限避免反复小区间充电
            let limit = targetLimit ?? (enabled ? settings.maxCharge : settings.minCharge)
            let value = min(max(ChargeLimits.minimum, limit), ChargeLimits.maximum)
            let currentSMCValue = smc.read(forKey: SMCPowerKeys.bclmKey.key, size: 1)?.first

            if !force && lastWrittenBCLM == value && currentSMCValue == UInt8(value) && chargingDisabled == !enabled {
                return true
            }
            os_log("intelBCLM: writing BCLM=%{public}d, targetLimit=%{public}d, currentSMC=%{public}d, force=%{public}d", value, limit, currentSMCValue.map(Int.init) ?? -1, force ? 1 : 0)
            success = smc.write([UInt8(value)], forKey: SMCPowerKeys.bclmKey.key)
            if success {
                lastWrittenBCLM = value
                if smc.isKeyAvailable(key: SMCPowerKeys.bfclKey.key, size: 1) {
                    let indicatorValue = max(ChargeLimits.minimum, value - 5)
                    _ = smc.write([UInt8(indicatorValue)], forKey: SMCPowerKeys.bfclKey.key)
                }
            } else {
                os_log("intelBCLM: writing BCLM=%{public}d FAILED", value)
            }
        }

        if success {
            chargingDisabled = !enabled
        }
        return success
    }

    private func setGoldenGateLimits(upper: Int, lower: Int) -> Bool {
        let clampedUpper = min(max(ChargeLimits.minimum, upper), ChargeLimits.maximum)
        let clampedLower = min(max(ChargeLimits.minimum, lower), clampedUpper)

        func word(_ value: Int) -> [UInt8] {
            let number = UInt32(value) << 24
            return [
                UInt8((number >> 24) & 0xFF),
                UInt8((number >> 16) & 0xFF),
                UInt8((number >> 8) & 0xFF),
                UInt8(number & 0xFF)
            ]
        }

        return smc.write([0], forKey: SMCPowerKeys.goldenGateCommitKey.key)
            && smc.write(word(clampedUpper), forKey: SMCPowerKeys.goldenGateUpperKey.key)
            && smc.write(word(clampedLower), forKey: SMCPowerKeys.goldenGateLowerKey.key)
            && smc.write([2], forKey: SMCPowerKeys.goldenGateCommitKey.key)
    }

    private func setAdapterEnabled(_ enabled: Bool) -> Bool {
        guard let adapterKey else {
            adapterDisabled = false
            return enabled
        }

        let bytes = enabled ? adapterKey.onBytes : adapterKey.offBytes
        let success = smc.write(bytes, forKey: adapterKey.info.key)
        if success { adapterDisabled = !enabled }
        return success
    }

    private func acquireSleepAssertion() {
        guard sleepAssertion == 0 else { return }
        var assertion: IOPMAssertionID = 0
        let name = "ChargeLmt 充电控制" as CFString
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            name,
            &assertion
        )
        if result == kIOReturnSuccess {
            sleepAssertion = assertion
        } else {
            lastError = "无法防止系统睡眠"
        }
    }

    private func releaseSleepAssertion() {
        guard sleepAssertion != 0 else { return }
        IOPMAssertionRelease(sleepAssertion)
        sleepAssertion = 0
    }

    private func persistSettings() {
        let directory = settingsURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        if let data = try? PropertyListEncoder().encode(settings) {
            try? data.write(to: settingsURL, options: .atomic)
        }
    }

    private static func readStoredSettings() -> StoredSettings {
        guard let data = try? Data(contentsOf: URL(
            fileURLWithPath: "/Library/Application Support/ChargeLmt/settings.plist"
        )), let stored = try? PropertyListDecoder().decode(
            StoredSettings.self,
            from: data
        ), ChargeLimits.isValid(
            minCharge: stored.minCharge,
            maxCharge: stored.maxCharge
        ) else { return StoredSettings() }
        return stored
    }

    private func array(_ value: [UInt8]?, equals expected: [UInt8]) -> Bool {
        guard let value else { return false }
        return value == expected
    }

    static var hardwareArchitecture: String {
        var size = 0
        guard sysctlbyname("hw.machine", nil, &size, nil, 0) == 0, size > 0 else {
            return "unknown"
        }

        var machine = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.machine", &machine, &size, nil, 0) == 0 else {
            return "unknown"
        }
        return String(cString: machine)
    }

    static func detectChargeBackend(
        smc: SMCCommunicator,
        architecture: String
    ) -> ChargeBackend? {
        if architecture == "arm64" || architecture.hasPrefix("arm") {
            if smc.isSupported(SMCPowerKeys.goldenGateUpperKey) &&
                smc.isSupported(SMCPowerKeys.goldenGateLowerKey) &&
                smc.isSupported(SMCPowerKeys.goldenGateCommitKey) {
                return .goldenGate
            }

            guard let key = SMCPowerKeys.chargeKeys.first(where: {
                smc.isKeyAvailable(key: $0.info.key, size: $0.info.dataSize)
            }) else { return nil }
            return .appleSilicon(key: key)
        }

        let availableIntelKeys = SMCPowerKeys.intelToggleKeys.filter {
            smc.isKeyAvailable(key: $0.info.key, size: $0.info.dataSize)
        }
        if !availableIntelKeys.isEmpty {
            return .intelToggle(keys: availableIntelKeys)
        }

        guard smc.isKeyAvailable(
            key: SMCPowerKeys.bclmKey.key,
            size: SMCPowerKeys.bclmKey.dataSize
        ) else { return nil }
        return .intelBCLM
    }

    private static func isChargingDisabled(
        smc: SMCCommunicator,
        backend: ChargeBackend,
        minCharge: Int = 60
    ) -> Bool {
        switch backend {
        case .appleSilicon(let key):
            let value = smc.read(forKey: key.info.key, size: key.onBytes.count)
            return !(value == key.onBytes)

        case .goldenGate:
            guard let bytes = smc.read(
                forKey: SMCPowerKeys.goldenGateUpperKey.key,
                size: 4
            ) else { return false }
            let value = UInt32(bytes[0]) << 24 |
                UInt32(bytes[1]) << 16 |
                UInt32(bytes[2]) << 8 |
                UInt32(bytes[3])
            let upper = Int(value >> 24)
            return upper <= minCharge

        case .intelToggle(let keys):
            return keys.contains { key in
                let value = smc.read(forKey: key.info.key, size: key.onBytes.count)
                return value != key.onBytes
            }

        case .intelBCLM:
            guard let bytes = smc.read(
                forKey: SMCPowerKeys.bclmKey.key,
                size: 1
            ), let value = bytes.first else { return false }
            return Int(value) <= minCharge
        }
    }
}
