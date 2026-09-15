import Foundation

/// Charge-control state as read from the hardware. Nil means unknown.
public struct ChargeHardwareState: Equatable, Sendable {
    public var chargingInhibited: Bool?
    public var dischargeForced: Bool?

    public init(chargingInhibited: Bool?, dischargeForced: Bool?) {
        self.chargingInhibited = chargingInhibited
        self.dischargeForced = dischargeForced
    }

    public static let defaults = ChargeHardwareState(chargingInhibited: false, dischargeForced: false)
}

public enum ChargeControlError: Error, CustomStringConvertible {
    /// Writes were accepted, but the keys read back differently.
    case notApplied(wanted: ChargeHardwareState, actual: ChargeHardwareState)
    case writesFailed([String])

    public var description: String {
        switch self {
        case .notApplied(let wanted, let actual):
            return "SMC didn't keep the requested state (wanted \(Self.describe(wanted)), read back \(Self.describe(actual)))"
        case .writesFailed(let messages):
            return messages.joined(separator: "; ")
        }
    }

    private static func describe(_ state: ChargeHardwareState) -> String {
        let charging = state.chargingInhibited.map { $0 ? "off" : "on" } ?? "?"
        let bypass = state.dischargeForced.map { $0 ? "on" : "off" } ?? "?"
        return "charging \(charging), adapter bypass \(bypass)"
    }
}

/// Something that can switch battery charging and adapter bypass on and off.
public protocol ChargeActuator: AnyObject {
    var backendDescription: String { get }
    var canForceDischarge: Bool { get }
    func readState() -> ChargeHardwareState
    /// Brings hardware in line with the request. Attempts every needed write even if one fails, never
    /// bypasses the adapter if anything else failed, and verifies the result. Throws on any failure.
    @discardableResult
    func apply(allowCharging: Bool, forceDischarge: Bool) throws -> (wrote: Bool, state: ChargeHardwareState)
    /// Re-enables charging and the adapter unconditionally, trying every key. Returns the failures.
    func restoreDefaults() -> [Error]
    /// Re-attaches the adapter, leaving charging as it is.
    func disableDischarge() throws
}

/// Controls charging on Apple Silicon via SMC keys.
///
/// - Charging inhibit: `CHTE` on current firmware (macOS 15+), `CH0B`/`CH0C` on older firmware.
/// - Adapter bypass (run on battery while plugged in): `CHIE` on current firmware, `CH0I` on older.
public final class SMCChargeController: ChargeActuator {
    private enum InhibitBackend {
        case chte(size: Int)
        case ch0x(keys: [String])
    }

    private let smc: SMCKeyAccess
    private let inhibit: InhibitBackend
    private let discharge: (key: String, on: UInt8)?
    private let retryDelay: useconds_t

    public convenience init() throws {
        try self.init(smc: SMC())
    }

    public init(smc: SMCKeyAccess, retryDelay: useconds_t = 20_000) throws {
        self.smc = smc
        self.retryDelay = retryDelay

        // Only treat a key as absent when the SMC says so. Guessing from a transient read failure
        // would lock in the wrong backend; throwing lets the daemon retry later instead.
        func probe(_ key: String) throws -> [UInt8]? {
            var attempt = 0
            while true {
                do {
                    return try smc.read(key)
                } catch SMCError.keyNotFound {
                    return nil
                } catch {
                    attempt += 1
                    if attempt >= 3 { throw error }
                    usleep(retryDelay * 2)
                }
            }
        }

        if let value = try probe("CHTE"), !value.isEmpty {
            inhibit = .chte(size: value.count)
        } else {
            let keys = try ["CH0B", "CH0C"].filter { try probe($0) != nil }
            guard !keys.isEmpty else { throw SMCError.unsupportedHardware }
            inhibit = .ch0x(keys: keys)
        }

        if try probe("CHIE") != nil {
            discharge = ("CHIE", 0x08)
        } else if try probe("CH0I") != nil {
            discharge = ("CH0I", 0x01)
        } else {
            discharge = nil
        }
    }

    public var backendDescription: String {
        let names = inhibitKeys.joined(separator: "/")
        return discharge.map { "\(names) + \($0.key)" } ?? names
    }

    public var canForceDischarge: Bool { discharge != nil }

    public func readState() -> ChargeHardwareState {
        combine(inhibitKeys.map(readInhibit), readDischarge())
    }

    @discardableResult
    public func apply(allowCharging: Bool, forceDischarge: Bool) throws -> (wrote: Bool, state: ChargeHardwareState) {
        let wantInhibit = !allowCharging || forceDischarge
        let wantDischarge = forceDischarge && discharge != nil
        let inhibitValues = inhibitKeys.map(readInhibit)
        let dischargeValue = readDischarge()
        var failures: [String] = []
        var wrote = false

        func attempt(_ key: String, _ bytes: [UInt8]) {
            do {
                try write(key, bytes)
                wrote = true
            } catch {
                failures.append("\(error)")
            }
        }

        // Re-attach the adapter before re-enabling charging.
        if !wantDischarge, let discharge, dischargeValue != false {
            attempt(discharge.key, [0x00])
        }
        // Check each key individually: firmware may reset just one of CH0B/CH0C.
        for (key, value) in zip(inhibitKeys, inhibitValues) where value != wantInhibit {
            attempt(key, inhibitBytes(on: wantInhibit))
        }
        // Only bypass the adapter once everything else is in place.
        if wantDischarge, failures.isEmpty, let discharge, dischargeValue != true {
            attempt(discharge.key, [discharge.on])
        }

        guard failures.isEmpty else { throw ChargeControlError.writesFailed(failures) }
        guard wrote else { return (false, combine(inhibitValues, dischargeValue)) }

        let wanted = ChargeHardwareState(chargingInhibited: wantInhibit, dischargeForced: wantDischarge)
        let actual = readState()
        guard actual == wanted else { throw ChargeControlError.notApplied(wanted: wanted, actual: actual) }
        return (true, actual)
    }

    public func restoreDefaults() -> [Error] {
        var errors: [Error] = []
        if let discharge {
            do { try write(discharge.key, [0x00]) } catch { errors.append(error) }
        }
        for key in inhibitKeys {
            do { try write(key, inhibitBytes(on: false)) } catch { errors.append(error) }
        }
        return errors
    }

    public func disableDischarge() throws {
        guard let discharge else { return }
        try write(discharge.key, [0x00])
    }

    // MARK: - Keys

    private var inhibitKeys: [String] {
        switch inhibit {
        case .chte: return ["CHTE"]
        case .ch0x(let keys): return keys
        }
    }

    private func inhibitBytes(on: Bool) -> [UInt8] {
        switch inhibit {
        case .chte(let size):
            var bytes = [UInt8](repeating: 0, count: size)
            if on { bytes[0] = 0x01 }
            return bytes
        case .ch0x:
            return [on ? 0x02 : 0x00]
        }
    }

    private func readInhibit(_ key: String) -> Bool? {
        (try? smc.read(key)).map(isSet)
    }

    private func readDischarge() -> Bool? {
        guard let discharge else { return false }
        return (try? smc.read(discharge.key)).map(isSet)
    }

    private func combine(_ inhibitValues: [Bool?], _ dischargeValue: Bool?) -> ChargeHardwareState {
        let inhibited: Bool? = inhibitValues.contains { $0 == nil } ? nil : inhibitValues.allSatisfy { $0 == true }
        return ChargeHardwareState(chargingInhibited: inhibited, dischargeForced: dischargeValue)
    }

    private func isSet(_ bytes: [UInt8]) -> Bool {
        bytes.contains { $0 != 0 }
    }

    /// Retries transient failures; permission, missing-key and size errors won't improve.
    private func write(_ key: String, _ bytes: [UInt8]) throws {
        var attempt = 0
        while true {
            do {
                return try smc.write(key, bytes)
            } catch SMCError.failed where attempt < 2 {
                attempt += 1
                usleep(retryDelay)
            }
        }
    }
}

/// Stands in when the SMC can't be controlled, so the daemon reports the problem (and retries)
/// instead of crash-looping.
public final class UnavailableChargeController: ChargeActuator {
    public let error: Error

    public init(error: Error) {
        self.error = error
    }

    public var backendDescription: String { "unavailable" }
    public var canForceDischarge: Bool { false }

    public func readState() -> ChargeHardwareState {
        ChargeHardwareState(chargingInhibited: nil, dischargeForced: nil)
    }

    public func apply(allowCharging: Bool, forceDischarge: Bool) throws -> (wrote: Bool, state: ChargeHardwareState) {
        throw error
    }

    public func restoreDefaults() -> [Error] { [error] }

    public func disableDischarge() throws { throw error }
}

/// In-memory actuator for `battery-anchord --dry-run`: logs decisions without touching hardware.
public final class DryRunChargeController: ChargeActuator {
    private var state = ChargeHardwareState.defaults

    public init() {}

    public var backendDescription: String { "dry-run (no SMC writes)" }
    public var canForceDischarge: Bool { true }

    public func readState() -> ChargeHardwareState { state }

    @discardableResult
    public func apply(allowCharging: Bool, forceDischarge: Bool) throws -> (wrote: Bool, state: ChargeHardwareState) {
        let next = ChargeHardwareState(chargingInhibited: !allowCharging || forceDischarge, dischargeForced: forceDischarge)
        defer { state = next }
        return (next != state, next)
    }

    public func restoreDefaults() -> [Error] {
        state = .defaults
        return []
    }

    public func disableDischarge() throws {
        state.dischargeForced = false
    }
}
