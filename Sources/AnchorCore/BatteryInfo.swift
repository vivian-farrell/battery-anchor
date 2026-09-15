import Foundation
import IOKit
import IOKit.ps

public struct BatterySnapshot: Codable, Equatable, Sendable {
    public var percent: Int
    public var externalPower: Bool
    public var isCharging: Bool
    public var cycleCount: Int?
    public var healthPercent: Int?
    public var temperatureC: Double?
}

public enum BatteryInfo {
    /// Reads the internal battery. Returns nil on Macs without one.
    public static func read() -> BatterySnapshot? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }

        for source in list {
            guard let desc = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  desc[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = desc[kIOPSCurrentCapacityKey] as? Int,
                  let max = desc[kIOPSMaxCapacityKey] as? Int, max > 0
            else { continue }

            var snapshot = BatterySnapshot(
                percent: Int((Double(current) / Double(max) * 100).rounded()),
                externalPower: desc[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue,
                isCharging: desc[kIOPSIsChargingKey] as? Bool ?? false
            )
            addRegistryDetails(to: &snapshot)
            return snapshot
        }
        return nil
    }

    private static func addRegistryDetails(to snapshot: inout BatterySnapshot) {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }

        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = props?.takeRetainedValue() as? [String: Any]
        else { return }

        snapshot.cycleCount = dict["CycleCount"] as? Int
        if let raw = dict["AppleRawMaxCapacity"] as? Int, let design = dict["DesignCapacity"] as? Int, design > 0 {
            snapshot.healthPercent = Int((Double(raw) / Double(design) * 100).rounded())
        }
        if let temp = dict["Temperature"] as? Int {
            snapshot.temperatureC = Double(temp) / 100
        }
    }
}
