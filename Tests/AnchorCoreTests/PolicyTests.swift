import Testing
@testable import AnchorCore

func anchor(max: Int = 80, buffer: Int = 5, sleepPause: Bool = true) -> AnchorConfig {
    var c = AnchorConfig()
    c.enabled = true
    c.maxCharge = max
    c.rechargeBuffer = buffer
    c.pauseChargingDuringSleep = sleepPause
    return c
}

/// Runs the policy over a sequence of battery levels, threading the phase through.
private func simulate(_ config: AnchorConfig, _ levels: [Int]) -> [Bool] {
    var machine = ChargeStateMachine(config: config)
    return levels.map { machine.decide(percent: $0, asleep: false, canForceDischarge: true).allowCharging }
}

private func decide(_ config: AnchorConfig, _ percent: Int, _ phase: ChargePhase? = nil, asleep: Bool = false, lidClosed: Bool = false) -> ChargeDecision {
    Policy.decide(config: config, percent: percent, previousPhase: phase, asleep: asleep, lidClosed: lidClosed)
}

// MARK: - Policy

@Test func offChargesNormally() {
    let d = decide(AnchorConfig(), 95, asleep: true)
    #expect(d.allowCharging && !d.forceDischarge)
    #expect(d.phase == nil)
}

@Test func defaultBufferIsFive() {
    #expect(AnchorConfig().rechargeBuffer == 5)
    #expect(anchor().rechargeLevel == 75)
}

@Test func holdsImmediatelyAtOrWithinBufferOfMax() {
    for percent in [80, 79, 76] {
        let d = decide(anchor(), percent)
        #expect(!d.allowCharging && !d.forceDischarge, "at \(percent)%")
        #expect(d.phase == .holding)
    }
}

@Test func driftBelowMaxDoesNotRecharge() {
    #expect(simulate(anchor(), [80, 79, 78, 77, 76]) == [false, false, false, false, false])
}

@Test func chargesFromRechargeLevelBackToMax() {
    let levels = [70, 76, 79, 80, 79, 76, 75, 78, 80]
    let expected = [true, true, true, false, false, false, true, true, false]
    #expect(simulate(anchor(), levels) == expected)
}

@Test func customBufferMovesRechargeLevel() {
    let config = anchor(buffer: 10)
    #expect(!decide(config, 72).allowCharging)
    #expect(decide(config, 70).allowCharging)
}

@Test func aboveMaxDischargesThenHolds() {
    var machine = ChargeStateMachine(config: anchor())
    var d = machine.decide(percent: 90, asleep: false, canForceDischarge: true)
    #expect(d.forceDischarge && !d.allowCharging)
    d = machine.decide(percent: 81, asleep: false, canForceDischarge: true)
    #expect(d.forceDischarge)
    d = machine.decide(percent: 80, asleep: false, canForceDischarge: true)
    #expect(!d.forceDischarge && !d.allowCharging)
    d = machine.decide(percent: 79, asleep: false, canForceDischarge: true)
    #expect(!d.forceDischarge && !d.allowCharging)
}

@Test func gaugeBounceAfterReachingMaxDoesNotRestartDischarge() {
    var machine = ChargeStateMachine(config: anchor())
    let bypass = [90, 80, 81, 80, 81, 82, 80].map { machine.decide(percent: $0, asleep: false, canForceDischarge: true).forceDischarge }
    #expect(bypass == [true, false, false, false, false, true, false])
}

@Test func firstEnableJustAboveMaxDischarges() {
    #expect(decide(anchor(), 81).forceDischarge)
}

@Test func overshootWhileChargingHolds() {
    let d = decide(anchor(), 81, .charging)
    #expect(!d.forceDischarge && !d.allowCharging)
}

@Test func unsupportedDischargeIsReportedNotClaimed() {
    let d = Policy.decide(config: anchor(), percent: 90, previousPhase: nil, asleep: false, canForceDischarge: false)
    #expect(!d.forceDischarge && !d.allowCharging)
    #expect(!d.reason.hasPrefix("Discharging"))
}

@Test func lidClosedNeverDischarges() {
    let d = decide(anchor(), 90, lidClosed: true)
    #expect(!d.forceDischarge && !d.allowCharging)
    #expect(d.phase == .discharging) // resumes when the lid opens
}

@Test func sleepPausesChargingJustBelowMax() {
    let d = decide(anchor(), 79, .charging, asleep: true)
    #expect(!d.allowCharging && !d.forceDischarge)
    #expect(d.phase == .charging) // finishes after wake
}

@Test func sleepKeepsChargingUntilCloseToMax() {
    #expect(decide(anchor(), 77, .charging, asleep: true).allowCharging)
    #expect(!decide(anchor(), 78, .charging, asleep: true).allowCharging)
}

@Test func wideBufferDoesNotEndOvernightChargeEarly() {
    // Reported case: max 70 with a 10-point buffer paused overnight at 61%, nine points short.
    #expect(decide(anchor(max: 70, buffer: 10), 61, .charging, asleep: true).allowCharging)
    #expect(!decide(anchor(max: 70, buffer: 10), 68, .charging, asleep: true).allowCharging)
}

@Test func sleepStillChargesBelowWindow() {
    #expect(decide(anchor(), 40, asleep: true).allowCharging)
}

@Test func sleepPauseCanBeDisabled() {
    #expect(decide(anchor(sleepPause: false), 79, .charging, asleep: true).allowCharging)
}

@Test func sleepNeverDischarges() {
    let d = decide(anchor(sleepPause: false), 90, asleep: true)
    #expect(!d.forceDischarge && !d.allowCharging)
}

@Test func criticalLevelAlwaysCharges() {
    #expect(decide(anchor(max: 20, buffer: 10), 5, .holding, asleep: true).allowCharging)
}

// MARK: - State machine

@Test func turningOnOrOffResetsPhase() {
    var machine = ChargeStateMachine(config: anchor())
    _ = machine.decide(percent: 60, asleep: false, canForceDischarge: true)
    #expect(machine.phase == .charging)
    machine.update(config: AnchorConfig())
    #expect(machine.phase == nil)
}

@Test func raisingMaxAboveBufferStartsCharging() {
    var machine = ChargeStateMachine(config: anchor())
    #expect(!machine.decide(percent: 80, asleep: false, canForceDischarge: true).allowCharging)
    machine.update(config: anchor(max: 90))
    #expect(machine.decide(percent: 80, asleep: false, canForceDischarge: true).allowCharging)
}

@Test func raisingMaxWithinBufferHolds() {
    var machine = ChargeStateMachine(config: anchor())
    _ = machine.decide(percent: 80, asleep: false, canForceDischarge: true)
    machine.update(config: anchor(max: 83))
    #expect(!machine.decide(percent: 80, asleep: false, canForceDischarge: true).allowCharging)
}

@Test func loweringMaxWellBelowCurrentDischarges() {
    var machine = ChargeStateMachine(config: anchor(max: 90))
    _ = machine.decide(percent: 88, asleep: false, canForceDischarge: true)
    machine.update(config: anchor(max: 80))
    #expect(machine.decide(percent: 88, asleep: false, canForceDischarge: true).forceDischarge)
}

@Test func restartResumesChargeInProgress() {
    var before = ChargeStateMachine(config: anchor())
    _ = before.decide(percent: 70, asleep: false, canForceDischarge: true)
    _ = before.decide(percent: 77, asleep: false, canForceDischarge: true)
    let status = makeStatus(config: before.config, phase: before.phase)

    var after = ChargeStateMachine(config: anchor())
    after.restorePhase(from: status)
    #expect(after.decide(percent: 77, asleep: false, canForceDischarge: true).allowCharging)
}

@Test func restartIgnoresPhaseWhenOnOffDiffers() {
    var machine = ChargeStateMachine(config: anchor())
    machine.restorePhase(from: makeStatus(config: AnchorConfig(), phase: .charging))
    #expect(machine.phase == nil)
}

// MARK: - Config

@Test func sanitizeClampsMaxAndBuffer() {
    var c = AnchorConfig()
    c.maxCharge = 150
    c.rechargeBuffer = 0
    #expect(c.sanitized().maxCharge == 100)
    #expect(c.sanitized().rechargeBuffer == 1)

    c.maxCharge = 30
    c.rechargeBuffer = 50
    #expect(c.sanitized().rechargeBuffer == 20)
    #expect(c.sanitized().rechargeLevel == AnchorConfig.minRechargeLevel)

    c.maxCharge = 5
    #expect(c.sanitized().maxCharge == 20)
}

@Test func configDecodesWithMissingKeys() throws {
    let config = try AnchorJSON.decoder.decode(AnchorConfig.self, from: .init(#"{"enabled":true,"maxCharge":70}"#.utf8))
    #expect(config.enabled)
    #expect(config.maxCharge == 70)
    #expect(config.rechargeBuffer == 5)
    #expect(config.pauseChargingDuringSleep)
}

func makeStatus(config: AnchorConfig, phase: ChargePhase?, controlling: Bool = false) -> AnchorStatus {
    AnchorStatus(
        updatedAt: .init(), daemonPID: 1, stopped: true, controlling: controlling, battery: nil, config: config,
        phase: phase, reason: "", chargingInhibited: false, dischargeForced: false, canForceDischarge: true,
        asleep: false, backend: "", error: nil
    )
}
