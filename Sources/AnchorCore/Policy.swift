import Foundation

public enum ChargePhase: String, Codable, Sendable {
    /// Climbing toward the maximum.
    case charging
    /// Not charging: the Mac runs from the charger.
    case holding
    /// Above the maximum: running on battery (while plugged in) down to it.
    case discharging
}

public struct ChargeDecision: Equatable, Sendable {
    public var allowCharging: Bool
    public var forceDischarge: Bool
    public var phase: ChargePhase?
    public var reason: String
}

public enum Policy {
    /// At or below this level, always charge.
    public static let criticalLevel = 5
    /// Once the maximum has been reached, discharging only restarts above max + this, so a gauge
    /// bouncing between max and max+1 doesn't flip the adapter on and off.
    public static let dischargeHysteresis = 1
    /// While asleep, charging stops this far below the maximum and finishes on wake. It follows the
    /// maximum rather than the recharge level, so a wide buffer doesn't end an overnight charge early.
    public static let sleepPauseMargin = 2

    public static func decide(
        config: AnchorConfig,
        percent: Int,
        previousPhase: ChargePhase?,
        asleep: Bool,
        lidClosed: Bool = false,
        canForceDischarge: Bool = true
    ) -> ChargeDecision {
        guard config.enabled else {
            return ChargeDecision(allowCharging: true, forceDischarge: false, phase: nil, reason: "Charging normally")
        }
        let maxCharge = config.maxCharge
        let rechargeLevel = config.rechargeLevel

        let phase: ChargePhase
        if percent <= rechargeLevel {
            phase = .charging
        } else if percent > maxCharge,
                  previousPhase == .discharging || percent > maxCharge + (previousPhase == nil ? 0 : dischargeHysteresis) {
            phase = .discharging
        } else if percent >= maxCharge {
            phase = .holding
        } else {
            // Inside the window: carry on charging if already charging; otherwise hold.
            // Small drifts below the maximum never trigger a top-up.
            phase = previousPhase == .charging ? .charging : .holding
        }

        if percent <= criticalLevel {
            return ChargeDecision(allowCharging: true, forceDischarge: false, phase: .charging, reason: "Battery critically low — charging")
        }

        switch phase {
        case .charging:
            // Nothing can stop a charge until the Mac wakes, so stop just short of the maximum and
            // finish on wake. Macs that wake briefly for network access reach the maximum mid-sleep;
            // one that sleeps straight through can overshoot, and is brought back down on waking.
            if asleep, config.pauseChargingDuringSleep, percent >= maxCharge - sleepPauseMargin {
                return ChargeDecision(allowCharging: false, forceDischarge: false, phase: phase, reason: "Charging paused while asleep")
            }
            return ChargeDecision(allowCharging: true, forceDischarge: false, phase: phase, reason: "Charging to \(maxCharge)%")

        case .holding:
            return ChargeDecision(allowCharging: false, forceDischarge: false, phase: phase, reason: "Holding — charges again at \(rechargeLevel)%")

        case .discharging:
            // Never bypass the adapter while asleep (nothing could stop the discharge at the maximum) or
            // with the lid closed (clamshell mode needs AC power, so the Mac would go to sleep).
            if asleep {
                return ChargeDecision(allowCharging: false, forceDischarge: false, phase: phase, reason: "Holding while asleep — above \(maxCharge)%")
            }
            if lidClosed {
                return ChargeDecision(
                    allowCharging: false, forceDischarge: false, phase: phase,
                    reason: "Holding — won't run on battery with the lid closed"
                )
            }
            if !canForceDischarge {
                return ChargeDecision(
                    allowCharging: false, forceDischarge: false, phase: phase,
                    reason: "Above \(maxCharge)% — this Mac can't run on battery while plugged in"
                )
            }
            return ChargeDecision(allowCharging: false, forceDischarge: true, phase: phase, reason: "Discharging to \(maxCharge)%")
        }
    }
}

/// Tracks the charge phase across decisions, config changes and daemon restarts.
public struct ChargeStateMachine: Sendable {
    public private(set) var config: AnchorConfig
    public private(set) var phase: ChargePhase?

    public init(config: AnchorConfig) {
        self.config = config
    }

    /// Resumes the phase from a previous daemon run, so a restart mid-charge doesn't abandon the charge.
    public mutating func restorePhase(from status: AnchorStatus) {
        guard status.config.enabled == config.enabled else { return }
        phase = status.phase
    }

    public mutating func update(config new: AnchorConfig) {
        if new.enabled != config.enabled {
            phase = nil
        }
        config = new
    }

    public mutating func decide(percent: Int, asleep: Bool, lidClosed: Bool = false, canForceDischarge: Bool) -> ChargeDecision {
        let decision = Policy.decide(
            config: config, percent: percent, previousPhase: phase, asleep: asleep,
            lidClosed: lidClosed, canForceDischarge: canForceDischarge
        )
        phase = decision.phase
        return decision
    }
}
