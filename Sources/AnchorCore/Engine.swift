import Foundation

/// The daemon's control loop, kept free of event sources and files so it can be tested.
///
/// It fails safe:
/// - If the battery can't be read, it restores normal charging.
/// - It never lets the Mac sleep with the adapter bypassed.
/// - When the limit is off, it restores normal charging once, then leaves the charge settings to macOS.
public final class AnchorEngine {
    public struct Environment {
        public var readBattery: () -> BatterySnapshot?
        public var isFullyAwake: () -> Bool
        public var isLidClosed: () -> Bool
        public var now: () -> Date

        public init(
            readBattery: @escaping () -> BatterySnapshot?,
            isFullyAwake: @escaping () -> Bool,
            isLidClosed: @escaping () -> Bool,
            now: @escaping () -> Date
        ) {
            self.readBattery = readBattery
            self.isFullyAwake = isFullyAwake
            self.isLidClosed = isLidClosed
            self.now = now
        }

        public static var system: Environment {
            Environment(
                readBattery: { BatteryInfo.read() },
                isFullyAwake: { SystemState.isFullyAwake() },
                isLidClosed: { SystemState.isLidClosed() },
                now: { Date() }
            )
        }
    }

    /// More writes than this within the window means something else keeps changing the settings back.
    static let interferenceThreshold = 12
    static let interferenceWindow: TimeInterval = 600
    static let actuatorRetryInterval: TimeInterval = 30
    static let interferenceMessage =
        "Charge settings keep being changed back; another charge tool or macOS feature may be fighting Battery Anchor"

    public private(set) var actuator: ChargeActuator
    public private(set) var machine = ChargeStateMachine(config: AnchorConfig())
    /// True while the charge settings may differ from normal because of us.
    public private(set) var controlling = false
    public var configError: String?

    private let makeActuator: (() throws -> ChargeActuator)?
    private let environment: Environment
    private let log: (String) -> Void
    private let publish: (AnchorStatus) -> Void

    private var sleepPending = false
    private var applyError: String?
    private var nextActuatorRetry = Date.distantPast
    private var recentWrites: [Date] = []
    private var interfering = false
    private var lastReason = ""
    private var lastLoggedReason: String?
    private var lastBattery: BatterySnapshot?

    public init(
        actuator: ChargeActuator,
        makeActuator: (() throws -> ChargeActuator)? = nil,
        environment: Environment = .system,
        log: @escaping (String) -> Void,
        publish: @escaping (AnchorStatus) -> Void
    ) {
        self.actuator = actuator
        self.makeActuator = makeActuator
        self.environment = environment
        self.log = log
        self.publish = publish
    }

    /// Asleep, about to sleep, or in a dark wake.
    public var isAsleep: Bool {
        sleepPending || !environment.isFullyAwake()
    }

    public func start(config: AnchorConfig, previous: AnchorStatus?) {
        machine = ChargeStateMachine(config: config)
        guard let previous else { return }
        machine.restorePhase(from: previous)
        if let phase = machine.phase {
            log("Resuming \(phase.rawValue) phase from previous run")
        }
        if previous.controlling {
            controlling = true
            log("Previous run didn't restore normal charging; taking over its charge settings")
        }
    }

    public func update(config: AnchorConfig) {
        machine.update(config: config)
    }

    public func willSleep() {
        sleepPending = true
        evaluate("will sleep")
        // Whatever happened above, don't sleep with the adapter bypassed: nothing could stop the discharge.
        if controlling, actuator.readState().dischargeForced != false {
            do {
                try actuator.disableDischarge()
                log("Re-attached the charger before sleep")
            } catch {
                recordApplyError("Couldn't re-attach the charger before sleep: \(error)")
            }
            publish(makeStatus(reason: lastReason, state: actuator.readState()))
        }
    }

    public func didWake() {
        sleepPending = false
        evaluate("woke")
    }

    public func evaluate(_ trigger: String) {
        retryActuatorIfNeeded()
        expireOldWrites()

        guard let battery = environment.readBattery() else {
            lastBattery = nil
            failSafe(trigger)
            return
        }
        lastBattery = battery

        let decision = machine.decide(
            percent: battery.percent, asleep: isAsleep, lidClosed: environment.isLidClosed(),
            canForceDischarge: actuator.canForceDischarge
        )

        guard machine.config.enabled else {
            if controlling { release() }
            let reason = controlling ? "Off — couldn't restore normal charging yet" : "Off — macOS manages charging"
            report(trigger, battery.percent, reason: reason, state: actuator.readState())
            return
        }

        if !controlling {
            controlling = true
            // Record ownership before the first write, so a crash mid-write gets cleaned up on restart.
            publish(makeStatus(reason: decision.reason, state: actuator.readState()))
        }

        var state: ChargeHardwareState
        do {
            let result = try actuator.apply(allowCharging: decision.allowCharging, forceDischarge: decision.forceDischarge)
            state = result.state
            if result.wrote {
                noteWrite("[\(trigger)] \(battery.percent)%: charging \(decision.allowCharging ? "on" : "off"), "
                    + "discharge \(decision.forceDischarge ? "on" : "off") — \(decision.reason)")
            }
            if applyError != nil { log("SMC writes recovered") }
            applyError = nil
        } catch {
            recordApplyError("Couldn't apply charge settings: \(error)")
            state = actuator.readState()
            // Never leave the adapter bypassed after a failure.
            if state.dischargeForced != false {
                try? actuator.disableDischarge()
                state = actuator.readState()
            }
        }
        report(trigger, battery.percent, reason: decision.reason, state: state)
    }

    /// Restores normal charging if we changed it, and publishes a final status.
    public func shutdown() {
        var reason = "Stopped"
        if controlling {
            let errors = actuator.restoreDefaults()
            if errors.isEmpty {
                controlling = false
                reason = "Stopped — normal charging restored"
            } else {
                reason = "Stopped — couldn't restore normal charging"
                recordApplyError("\(reason): \(describe(errors))")
            }
        }
        log(reason)
        publish(makeStatus(reason: reason, state: actuator.readState(), stopped: true))
    }

    // MARK: - Helpers

    private func failSafe(_ trigger: String) {
        var reason = "Can't read the battery"
        if controlling {
            let errors = actuator.restoreDefaults()
            if errors.isEmpty {
                reason += " — normal charging restored"
            } else {
                recordApplyError("Couldn't restore normal charging: \(describe(errors))")
            }
            // Stay in control so the limit resumes as soon as readings come back.
        }
        report(trigger, nil, reason: reason, state: actuator.readState())
    }

    private func release() {
        let errors = actuator.restoreDefaults()
        if errors.isEmpty {
            controlling = false
            applyError = nil
            log("Limit off — normal charging restored; leaving charge settings to macOS")
        } else {
            recordApplyError("Couldn't restore normal charging: \(describe(errors))")
        }
    }

    private func report(_ trigger: String, _ percent: Int?, reason: String, state: ChargeHardwareState) {
        lastReason = reason
        if reason != lastLoggedReason {
            log("[\(trigger)] \(percent.map { "\($0)%" } ?? "?"): \(reason)")
            lastLoggedReason = reason
        }
        publish(makeStatus(reason: reason, state: state))
    }

    private func noteWrite(_ message: String) {
        recentWrites.append(environment.now())
        if recentWrites.count > Self.interferenceThreshold {
            if !interfering {
                interfering = true
                log("WARN \(Self.interferenceMessage). Pausing per-change log lines.")
            }
        } else if !interfering {
            log(message)
        }
    }

    private func expireOldWrites() {
        let now = environment.now()
        recentWrites.removeAll { now.timeIntervalSince($0) >= Self.interferenceWindow }
        if interfering, recentWrites.count <= 2 {
            interfering = false
            log("Charge settings are stable again")
        }
    }

    private func retryActuatorIfNeeded() {
        guard actuator is UnavailableChargeController, let makeActuator else { return }
        let now = environment.now()
        guard now >= nextActuatorRetry else { return }
        nextActuatorRetry = now.addingTimeInterval(Self.actuatorRetryInterval)
        if let replacement = try? makeActuator() {
            actuator = replacement
            applyError = nil
            log("Charge control available (backend: \(replacement.backendDescription))")
        }
    }

    private func recordApplyError(_ message: String) {
        if message != applyError { log("ERROR \(message)") }
        applyError = message
    }

    private func describe(_ errors: [Error]) -> String {
        errors.map { "\($0)" }.joined(separator: "; ")
    }

    private func makeStatus(reason: String, state: ChargeHardwareState, stopped: Bool = false) -> AnchorStatus {
        AnchorStatus(
            updatedAt: environment.now(),
            daemonPID: getpid(),
            stopped: stopped,
            controlling: controlling,
            battery: lastBattery,
            config: machine.config,
            phase: machine.phase,
            reason: reason,
            chargingInhibited: state.chargingInhibited,
            dischargeForced: state.dischargeForced,
            canForceDischarge: actuator.canForceDischarge,
            asleep: isAsleep,
            backend: actuator.backendDescription,
            error: configError ?? applyError ?? (interfering ? Self.interferenceMessage : nil)
        )
    }
}
