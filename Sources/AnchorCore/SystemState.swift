import Foundation
import IOKit

public enum SystemState {
    // Bits of IOPMrootDomain's "System Capabilities" property (kIOPMSystemCapability* in the kernel).
    private static let capabilityCPU = 0x1
    private static let capabilityGraphics = 0x2

    /// False while asleep or in a dark wake (Power Nap, maintenance wakes), when the system runs without
    /// graphics. Dark wakes also deliver "has powered on", but the user isn't there and the lid may be closed.
    public static func isFullyAwake() -> Bool {
        guard let capabilities = rootDomainProperty("System Capabilities") as? Int else {
            return true // Can't tell; the daemon's own sleep notifications still apply.
        }
        return capabilities & capabilityCPU != 0 && capabilities & capabilityGraphics != 0
    }

    /// True when a MacBook's lid is closed (clamshell mode), which only stays awake on AC power.
    public static func isLidClosed() -> Bool {
        (rootDomainProperty("AppleClamshellState") as? Bool) ?? false
    }

    private static func rootDomainProperty(_ key: String) -> Any? {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return nil }
        defer { IOObjectRelease(root) }
        return IORegistryEntryCreateCFProperty(root, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
}
