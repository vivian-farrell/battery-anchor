import Foundation

public struct AnchorConfig: Codable, Equatable, Sendable {
    public static let maxChargeRange = 20...100
    public static let minRechargeLevel = 10
    public static let defaultRechargeBuffer = 5

    /// When off, macOS charges normally.
    public var enabled = false
    /// Charge up to this level, then hold. Above it, run on battery down to it.
    public var maxCharge = 80
    /// Charging resumes once the battery is this many points below `maxCharge`.
    public var rechargeBuffer = AnchorConfig.defaultRechargeBuffer
    /// While asleep, stop charging just below `maxCharge` (see `Policy.sleepPauseMargin`) and finish on wake,
    /// so an unattended sleep can't carry the battery well past the maximum.
    public var pauseChargingDuringSleep = true

    /// The level at or below which charging starts again.
    public var rechargeLevel: Int { maxCharge - rechargeBuffer }

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AnchorConfig()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        maxCharge = try c.decodeIfPresent(Int.self, forKey: .maxCharge) ?? d.maxCharge
        rechargeBuffer = try c.decodeIfPresent(Int.self, forKey: .rechargeBuffer) ?? d.rechargeBuffer
        pauseChargingDuringSleep = try c.decodeIfPresent(Bool.self, forKey: .pauseChargingDuringSleep) ?? d.pauseChargingDuringSleep
    }

    /// The largest buffer allowed for a given maximum, keeping the recharge level at or above `minRechargeLevel`.
    public static func maxRechargeBuffer(for maxCharge: Int) -> Int {
        maxCharge - minRechargeLevel
    }

    public func sanitized() -> AnchorConfig {
        var c = self
        c.maxCharge = min(max(c.maxCharge, Self.maxChargeRange.lowerBound), Self.maxChargeRange.upperBound)
        c.rechargeBuffer = min(max(c.rechargeBuffer, 1), Self.maxRechargeBuffer(for: c.maxCharge))
        return c
    }
}

public enum AnchorJSON {
    public static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    public static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
