import Foundation
import IOKit
import IOKit.ps

struct BatterySnapshot {
    var percent: Int
    var isCharging: Bool
    var isAdapterConnected: Bool
}

enum BatteryMonitor {
    static func read() -> BatterySnapshot? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let powerSources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }

        for powerSource in powerSources {
            guard let description = IOPSGetPowerSourceDescription(info, powerSource)?
                .takeUnretainedValue() as? [String: Any]
            else { continue }

            let capacity = description[kIOPSCurrentCapacityKey as String] as? Int
            let maxCapacity = description[kIOPSMaxCapacityKey as String] as? Int
            let charging = description[kIOPSIsChargingKey as String] as? Bool
            let state = description[kIOPSPowerSourceStateKey as String] as? String
            if let capacity, let charging, let state {
                let percent: Int
                if let max = maxCapacity, max > 0, max != 100 {
                    percent = Int(round(Double(capacity) / Double(max) * 100.0))
                } else {
                    percent = capacity
                }
                return BatterySnapshot(
                    percent: percent,
                    isCharging: charging,
                    isAdapterConnected: state == "AC Power"
                )
            }
        }

        return registrySnapshot()
    }

    private static func registrySnapshot() -> BatterySnapshot? {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("AppleSmartBattery")
        )
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }

        var properties: Unmanaged<CFMutableDictionary>?
        let result = IORegistryEntryCreateCFProperties(
            service,
            &properties,
            kCFAllocatorDefault,
            0
        )
        guard result == KERN_SUCCESS,
              let dictionary = properties?.takeRetainedValue() as? [String: Any]
        else { return nil }

        guard let current = dictionary["CurrentCapacity"] as? Int else { return nil }
        let percent: Int
        if let max = dictionary["MaxCapacity"] as? Int, max > 0, max != 100 {
            percent = Int(round(Double(current) / Double(max) * 100.0))
        } else {
            percent = current
        }
        let adapter = dictionary["ExternalConnected"] as? Bool ?? false
        let charging = dictionary["IsCharging"] as? Bool ?? false
        return BatterySnapshot(
            percent: percent,
            isCharging: charging,
            isAdapterConnected: adapter
        )
    }
}
