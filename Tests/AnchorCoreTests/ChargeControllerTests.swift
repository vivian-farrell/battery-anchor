import Testing
@testable import AnchorCore

/// In-memory SMC with injectable failures.
final class FakeSMC: SMCKeyAccess {
    var values: [String: [UInt8]]
    /// Number of upcoming reads/writes of a key that fail with a transient error.
    var failingReads: [String: Int] = [:]
    var failingWrites: [String: Int] = [:]
    /// Keys whose writes are accepted but not kept.
    var ignoredWrites: Set<String> = []
    private(set) var writes: [String] = []

    init(_ values: [String: [UInt8]]) {
        self.values = values
    }

    func read(_ key: String) throws -> [UInt8] {
        if let remaining = failingReads[key], remaining > 0 {
            failingReads[key] = remaining - 1
            throw SMCError.failed(key, 5)
        }
        guard let value = values[key] else { throw SMCError.keyNotFound(key) }
        return value
    }

    func write(_ key: String, _ bytes: [UInt8]) throws {
        writes.append(key)
        if let remaining = failingWrites[key], remaining > 0 {
            failingWrites[key] = remaining - 1
            throw SMCError.failed(key, 5)
        }
        guard values[key] != nil else { throw SMCError.keyNotFound(key) }
        if !ignoredWrites.contains(key) { values[key] = bytes }
    }
}

private func modern(chte: [UInt8] = [0, 0, 0, 0], chie: [UInt8] = [0]) -> FakeSMC {
    FakeSMC(["CHTE": chte, "CHIE": chie])
}

@Test func detectsModernBackend() throws {
    let controller = try SMCChargeController(smc: modern(), retryDelay: 0)
    #expect(controller.backendDescription == "CHTE + CHIE")
    #expect(controller.canForceDischarge)
}

@Test func transientProbeFailureThrowsInsteadOfPickingWrongBackend() {
    let smc = FakeSMC(["CHTE": [0, 0, 0, 0], "CH0B": [0]])
    smc.failingReads["CHTE"] = 10
    #expect(throws: SMCError.self) {
        try SMCChargeController(smc: smc, retryDelay: 0)
    }
}

@Test func briefProbeFailureIsRetried() throws {
    let smc = modern()
    smc.failingReads["CHTE"] = 1
    #expect(try SMCChargeController(smc: smc, retryDelay: 0).backendDescription == "CHTE + CHIE")
}

@Test func applyVerifiesAndReportsState() throws {
    let smc = modern()
    let controller = try SMCChargeController(smc: smc, retryDelay: 0)
    let result = try controller.apply(allowCharging: false, forceDischarge: true)
    #expect(result.wrote)
    #expect(result.state == ChargeHardwareState(chargingInhibited: true, dischargeForced: true))
    #expect(smc.values["CHTE"] == [1, 0, 0, 0] && smc.values["CHIE"] == [0x08])
}

@Test func applyWontBypassAdapterIfInhibitFails() throws {
    let smc = modern()
    let controller = try SMCChargeController(smc: smc, retryDelay: 0)
    smc.failingWrites["CHTE"] = 100
    #expect(throws: ChargeControlError.self) {
        try controller.apply(allowCharging: false, forceDischarge: true)
    }
    #expect(smc.values["CHIE"] == [0])
}

@Test func applyThrowsWhenWriteDoesNotStick() throws {
    let smc = modern()
    let controller = try SMCChargeController(smc: smc, retryDelay: 0)
    smc.ignoredWrites = ["CHTE"]
    #expect(throws: ChargeControlError.self) {
        try controller.apply(allowCharging: false, forceDischarge: false)
    }
}

@Test func transientWriteFailureIsRetried() throws {
    let smc = modern()
    let controller = try SMCChargeController(smc: smc, retryDelay: 0)
    smc.failingWrites["CHTE"] = 2
    #expect(try controller.apply(allowCharging: false, forceDischarge: false).wrote)
}

@Test func restoreTriesEveryKeyEvenIfOneFails() throws {
    let smc = modern(chte: [1, 0, 0, 0], chie: [0x08])
    let controller = try SMCChargeController(smc: smc, retryDelay: 0)
    smc.failingWrites["CHIE"] = 100
    let errors = controller.restoreDefaults()
    #expect(errors.count == 1)
    #expect(smc.values["CHTE"] == [0, 0, 0, 0])
}

@Test func legacyInhibitKeysAreCheckedIndividually() throws {
    let smc = FakeSMC(["CH0B": [0x02], "CH0C": [0x00]])
    let controller = try SMCChargeController(smc: smc, retryDelay: 0)
    #expect(controller.readState().chargingInhibited == false) // only half set
    try controller.apply(allowCharging: false, forceDischarge: false)
    #expect(smc.writes == ["CH0C"])
    #expect(controller.readState().chargingInhibited == true)
}
