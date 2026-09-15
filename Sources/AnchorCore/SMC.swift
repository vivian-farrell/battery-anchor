import CSMC
import Foundation

public enum SMCError: Error, CustomStringConvertible {
    case openFailed
    case keyNotFound(String)
    case notPrivileged(String)
    case sizeMismatch(String)
    case failed(String, Int32)
    case unsupportedHardware

    public var description: String {
        switch self {
        case .openFailed: return "Could not open the AppleSMC service"
        case .keyNotFound(let key): return "SMC key \(key) not found"
        case .notPrivileged(let key): return "Writing SMC key \(key) requires root"
        case .sizeMismatch(let key): return "Unexpected data size for SMC key \(key)"
        case .failed(let key, let code): return "SMC operation on \(key) failed (code \(code))"
        case .unsupportedHardware: return "This Mac doesn't expose supported charge-control SMC keys (Apple Silicon required)"
        }
    }
}

/// Raw SMC key access, abstracted so charge-control logic can be tested without hardware.
public protocol SMCKeyAccess: AnyObject {
    func read(_ key: String) throws -> [UInt8]
    func write(_ key: String, _ bytes: [UInt8]) throws
}

/// Thin wrapper over the AppleSMC user client. Reads work unprivileged; writes need root.
public final class SMC: SMCKeyAccess {
    private var conn: UInt32 = 0

    public init() throws {
        guard smc_open(&conn) == SMC_OK else { throw SMCError.openFailed }
    }

    deinit { smc_close(conn) }

    public func read(_ key: String) throws -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: 32)
        var size: UInt32 = 32
        var type: UInt32 = 0
        let result = key.withCString { smc_read_key(conn, $0, &buffer, &size, &type) }
        try check(result, key)
        return Array(buffer.prefix(Int(min(size, 32))))
    }

    public func exists(_ key: String) -> Bool {
        (try? read(key)) != nil
    }

    public func write(_ key: String, _ bytes: [UInt8]) throws {
        let result = key.withCString { smc_write_key(conn, $0, bytes, UInt32(bytes.count)) }
        try check(result, key)
    }

    private func check(_ result: Int32, _ key: String) throws {
        switch result {
        case SMC_OK: return
        case SMC_ERR_NOT_FOUND: throw SMCError.keyNotFound(key)
        case SMC_ERR_NOT_PRIVILEGED: throw SMCError.notPrivileged(key)
        case SMC_ERR_SIZE_MISMATCH: throw SMCError.sizeMismatch(key)
        default: throw SMCError.failed(key, result)
        }
    }
}
