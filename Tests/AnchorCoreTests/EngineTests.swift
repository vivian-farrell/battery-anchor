import Foundation
import Testing
@testable import AnchorCore

struct TestError: Error {}

final class FakeActuator: ChargeActuator {
    var state = ChargeHardwareState.defaults
    var applyError: Error?
    var restoreErrors: [Error] = []
    private(set) var calls: [String] = []

    var backendDescription: String { "fake" }
    var canForceDischarge: Bool { true }

    func readState() -> ChargeHardwareState { state }

    func apply(allowCharging: Bool, forceDischarge: Bool) throws -> (wrote: Bool, state: ChargeHardwareState) {
        calls.append("apply")
        if let applyError { throw applyError }
        let next = ChargeHardwareState(chargingInhibited: !allowCharging || forceDischarge, dischargeForced: forceDischarge)
        defer { state = next }
        return (next != state, next)
    }

    func restoreDefaults() -> [Error] {
        calls.append("restore")
        if restoreErrors.isEmpty { state = .defaults }
        return restoreErrors
    }

    func disableDischarge() throws {
        calls.append("disableDischarge")
        state.dischargeForced = false
    }
}

final class Harness {
    var percent: Int? = 80
    var fullyAwake = true
    var lidClosed = false
    var now = Date(timeIntervalSince1970: 1_000_000)
    var logs: [String] = []
    var published: [AnchorStatus] = []
    let actuator: ChargeActuator
    private(set) var engine: AnchorEngine!

    init(actuator: ChargeActuator = FakeActuator(), makeActuator: (() throws -> ChargeActuator)? = nil) {
        self.actuator = actuator
        let environment = AnchorEngine.Environment(
            readBattery: { [unowned self] in percent.map { BatterySnapshot(percent: $0, externalPower: true, isCharging: false) } },
            isFullyAwake: { [unowned self] in fullyAwake },
            isLidClosed: { [unowned self] in lidClosed },
            now: { [unowned self] in now }
        )
        engine = AnchorEngine(
            actuator: actuator, makeActuator: makeActuator, environment: environment,
            log: { [unowned self] in logs.append($0) },
            publish: { [unowned self] in published.append($0) }
        )
    }

    var fake: FakeActuator { actuator as! FakeActuator }
    var last: AnchorStatus { published.last! }
}

@Test func offLeavesChargeSettingsToMacOS() {
    let h = Harness()
    h.fake.state = ChargeHardwareState(chargingInhibited: true, dischargeForced: false) // e.g. Optimized Charging
    h.engine.start(config: AnchorConfig(), previous: nil)
    h.engine.evaluate("test")
    h.engine.evaluate("test")
    #expect(h.fake.calls.isEmpty)
    #expect(h.fake.state.chargingInhibited == true)
    #expect(!h.last.controlling)
}

@Test func turningOffRestoresOnceThenStopsTouchingSettings() {
    let h = Harness()
    h.percent = 90
    h.engine.start(config: anchor(), previous: nil)
    h.engine.evaluate("on")
    #expect(h.fake.state.dischargeForced == true)

    h.engine.update(config: AnchorConfig())
    h.engine.evaluate("off")
    h.engine.evaluate("off again")
    #expect(h.fake.calls.filter { $0 == "restore" }.count == 1)
    #expect(h.fake.state == .defaults)
    #expect(!h.last.controlling)
}

@Test func restartAfterCrashRestoresLeftoverSettings() {
    let h = Harness()
    h.fake.state = ChargeHardwareState(chargingInhibited: true, dischargeForced: true)
    h.engine.start(config: AnchorConfig(), previous: makeStatus(config: anchor(), phase: .discharging, controlling: true))
    h.engine.evaluate("startup")
    #expect(h.fake.calls == ["restore"])
    #expect(h.fake.state == .defaults)
}

@Test func unreadableBatteryRestoresNormalCharging() {
    let h = Harness()
    h.percent = 90
    h.engine.start(config: anchor(), previous: nil)
    h.engine.evaluate("discharging")
    #expect(h.fake.state.dischargeForced == true)

    h.percent = nil
    h.engine.evaluate("battery gone")
    #expect(h.fake.state == .defaults)
    #expect(h.last.reason.contains("Can't read the battery"))
    #expect(h.last.controlling) // resumes once readings return

    h.percent = 90
    h.engine.evaluate("battery back")
    #expect(h.fake.state.dischargeForced == true)
}

@Test func failedRestoreIsRetriedAndReported() {
    let h = Harness()
    h.engine.start(config: anchor(), previous: nil)
    h.engine.evaluate("on")
    h.fake.restoreErrors = [TestError()]
    h.engine.update(config: AnchorConfig())
    h.engine.evaluate("off")
    h.engine.evaluate("off again")
    #expect(h.fake.calls.filter { $0 == "restore" }.count == 2)
    #expect(h.last.controlling)
    #expect(h.last.error != nil)
}

@Test func applyFailureNeverLeavesAdapterBypassed() {
    let h = Harness()
    h.percent = 90
    h.engine.start(config: anchor(), previous: nil)
    h.engine.evaluate("discharging")
    h.fake.applyError = TestError()
    h.engine.evaluate("failing")
    #expect(h.fake.state.dischargeForced == false)
    #expect(h.last.error != nil)
}

@Test func willSleepReattachesChargerEvenIfApplyFails() {
    let h = Harness()
    h.percent = 90
    h.engine.start(config: anchor(), previous: nil)
    h.engine.evaluate("discharging")
    h.fake.applyError = TestError()
    h.engine.willSleep()
    #expect(h.fake.calls.contains("disableDischarge"))
    #expect(h.fake.state.dischargeForced == false)
}

@Test func darkWakeCountsAsAsleep() {
    let h = Harness()
    h.percent = 90
    h.engine.start(config: anchor(), previous: nil)
    h.engine.didWake()
    h.fullyAwake = false
    h.engine.evaluate("dark wake")
    #expect(h.fake.state.dischargeForced == false)
    #expect(h.last.asleep)

    h.fullyAwake = true
    h.engine.evaluate("full wake")
    #expect(h.fake.state.dischargeForced == true)
}

@Test func lidClosedHoldsInsteadOfDischarging() {
    let h = Harness()
    h.percent = 90
    h.lidClosed = true
    h.engine.start(config: anchor(), previous: nil)
    h.engine.evaluate("clamshell")
    #expect(h.fake.state == ChargeHardwareState(chargingInhibited: true, dischargeForced: false))
}

@Test func shutdownReportsFailedRestoreHonestly() {
    let h = Harness()
    h.engine.start(config: anchor(), previous: nil)
    h.engine.evaluate("on")
    h.fake.restoreErrors = [TestError()]
    h.engine.shutdown()
    #expect(h.last.stopped)
    #expect(h.last.controlling)
    #expect(h.last.reason.contains("couldn't restore"))
}

@Test func shutdownWhenOffDoesNotTouchSettings() {
    let h = Harness()
    h.engine.start(config: AnchorConfig(), previous: nil)
    h.engine.evaluate("off")
    h.engine.shutdown()
    #expect(h.fake.calls.isEmpty)
    #expect(h.last.reason == "Stopped")
}

@Test func repeatedResetsRaiseInterferenceWarningAndQuietLogs() {
    let h = Harness()
    h.engine.start(config: anchor(), previous: nil)
    for _ in 0..<30 {
        h.fake.state = .defaults // something else keeps re-enabling charging
        h.engine.evaluate("reset")
        h.now += 10
    }
    #expect(h.last.error == AnchorEngine.interferenceMessage)
    let writeLines = h.logs.filter { $0.contains("charging off") }
    #expect(writeLines.count <= AnchorEngine.interferenceThreshold)

    h.now += AnchorEngine.interferenceWindow
    h.engine.evaluate("quiet")
    #expect(h.last.error == nil)
}

@Test func unavailableControllerIsRetried() {
    var attempts = 0
    let replacement = FakeActuator()
    let h = Harness(actuator: UnavailableChargeController(error: TestError()), makeActuator: {
        attempts += 1
        if attempts < 2 { throw TestError() }
        return replacement
    })
    h.engine.start(config: anchor(), previous: nil)
    h.engine.evaluate("first")
    #expect(h.engine.actuator is UnavailableChargeController)
    h.engine.evaluate("too soon")
    #expect(attempts == 1)

    h.now += AnchorEngine.actuatorRetryInterval
    h.engine.evaluate("retry")
    #expect(h.engine.actuator === replacement)
    #expect(replacement.calls == ["apply"])
}
