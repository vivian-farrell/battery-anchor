import Foundation

// Display text shared by the CLI and menu bar app.

extension BatterySnapshot {
    public func powerDescription(adapterBypassed: Bool) -> String {
        if externalPower {
            return isCharging ? "Plugged in, charging" : "Plugged in, not charging"
        }
        return adapterBypassed ? "Running on battery (charger bypassed)" : "On battery"
    }

    /// e.g. "99% capacity · 42 cycles · 30°C"; empty if nothing is known.
    public var healthSummary: String {
        var parts: [String] = []
        if let healthPercent { parts.append("\(healthPercent)% capacity") }
        if let cycleCount { parts.append("\(cycleCount) cycles") }
        if let temperatureC { parts.append(String(format: "%.0f°C", temperatureC)) }
        return parts.joined(separator: " · ")
    }
}

extension AnchorConfig {
    public var summary: String {
        guard enabled else { return "Off (normal charging)" }
        return "On — max \(maxCharge)%, charges again at \(rechargeLevel)%"
    }
}
