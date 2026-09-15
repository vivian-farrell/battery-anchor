import Foundation

/// What the daemon last did, published for the CLI and menu bar app.
public struct AnchorStatus: Codable, Equatable, Sendable {
    public var updatedAt: Date
    public var daemonPID: Int32
    /// True when the daemon has shut down (see `reason` for whether charging was restored).
    public var stopped: Bool
    /// True while the daemon may have changed the charge settings from normal. A new daemon run that
    /// finds this set (after a crash or failed restore) restores or re-applies them.
    public var controlling: Bool
    public var battery: BatterySnapshot?
    public var config: AnchorConfig
    public var phase: ChargePhase?
    public var reason: String
    /// Nil when the hardware state couldn't be read.
    public var chargingInhibited: Bool?
    public var dischargeForced: Bool?
    public var canForceDischarge: Bool
    public var asleep: Bool
    public var backend: String
    public var error: String?

    public init(
        updatedAt: Date, daemonPID: Int32, stopped: Bool, controlling: Bool, battery: BatterySnapshot?, config: AnchorConfig,
        phase: ChargePhase?, reason: String, chargingInhibited: Bool?, dischargeForced: Bool?, canForceDischarge: Bool,
        asleep: Bool, backend: String, error: String?
    ) {
        self.updatedAt = updatedAt
        self.daemonPID = daemonPID
        self.stopped = stopped
        self.controlling = controlling
        self.battery = battery
        self.config = config
        self.phase = phase
        self.reason = reason
        self.chargingInhibited = chargingInhibited
        self.dischargeForced = dischargeForced
        self.canForceDischarge = canForceDischarge
        self.asleep = asleep
        self.backend = backend
        self.error = error
    }
}

public enum AnchorStoreError: Error, CustomStringConvertible, LocalizedError {
    case invalidConfig(path: String, reason: String)
    case notRegularFile(path: String)

    public var description: String {
        switch self {
        case .invalidConfig(let path, let reason):
            return "\(path) is invalid (\(reason)); fix or delete it"
        case .notRegularFile(let path):
            return "\(path) is not a regular file"
        }
    }

    public var errorDescription: String? { description }
}

/// Shared files.
///
/// - `<dir>/status.json`: written by the daemon. The directory is root-only (`root:wheel 0755`).
/// - `<dir>/settings/config.json`: written by the CLI and app. The directory is admin-writable (`root:admin 0775`).
public struct AnchorStore {
    public static let daemonLabel = "dev.batteryanchor.daemon"
    /// The daemon refreshes status at least this often.
    public static let statusInterval: TimeInterval = 60

    public let directory: URL

    public init(directory: URL = AnchorStore.defaultDirectory) {
        self.directory = directory
    }

    public static var defaultDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["BATTERY_ANCHOR_SUPPORT_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return URL(fileURLWithPath: "/Library/Application Support/BatteryAnchor", isDirectory: true)
    }

    public var settingsDirectory: URL { directory.appendingPathComponent("settings", isDirectory: true) }
    public var configURL: URL { settingsDirectory.appendingPathComponent("config.json") }
    public var statusURL: URL { directory.appendingPathComponent("status.json") }

    // MARK: Config

    /// Returns nil if config.json doesn't exist; throws if it exists but can't be used.
    public func readConfig() throws -> AnchorConfig? {
        guard let data = try Self.readRegularFile(configURL) else { return nil }
        return try decodeConfig(data)
    }

    public func decodeConfig(_ data: Data) throws -> AnchorConfig {
        do {
            return try AnchorJSON.decoder.decode(AnchorConfig.self, from: data).sanitized()
        } catch {
            throw AnchorStoreError.invalidConfig(path: configURL.path, reason: Self.describe(error))
        }
    }

    public func saveConfig(_ config: AnchorConfig, group: gid_t? = nil) throws {
        try Self.writeAtomically(AnchorJSON.encoder.encode(config.sanitized()), to: configURL, permissions: 0o664, group: group)
    }

    /// Read-modify-write, so the CLI and app never overwrite each other's settings with stale copies.
    /// A missing config starts from defaults; an unreadable one throws instead of being replaced.
    @discardableResult
    public func updateConfig(_ change: (inout AnchorConfig) throws -> Void) throws -> AnchorConfig {
        var config = try readConfig() ?? AnchorConfig()
        try change(&config)
        config = config.sanitized()
        try saveConfig(config)
        return config
    }

    // MARK: Status

    public func loadStatus() -> AnchorStatus? {
        guard let data = try? Self.readRegularFile(statusURL, maxSize: 1 << 20) else { return nil }
        return try? AnchorJSON.decoder.decode(AnchorStatus.self, from: data)
    }

    public func writeStatus(_ status: AnchorStatus) throws {
        try Self.writeAtomically(AnchorJSON.encoder.encode(status), to: statusURL, permissions: 0o644)
    }

    /// True if the daemon is running: not cleanly stopped, status is fresh, and its process still exists.
    public static func isDaemonAlive(_ status: AnchorStatus, now: Date = Date()) -> Bool {
        guard !status.stopped, now.timeIntervalSince(status.updatedAt) < statusInterval * 3 else { return false }
        // EPERM means the (root) process exists but we can't signal it.
        return kill(status.daemonPID, 0) == 0 || errno == EPERM
    }

    // MARK: File primitives

    /// Writes via a fresh temp file and rename. The temp file is created with O_EXCL|O_NOFOLLOW and its
    /// permissions are set on the descriptor, so a planted file or symlink is never written through;
    /// rename replaces the destination entry itself rather than following it.
    public static func writeAtomically(_ data: Data, to url: URL, permissions: mode_t, group: gid_t? = nil) throws {
        let temp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)").path
        let fd = open(temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, permissions)
        guard fd >= 0 else { throw posixError() }
        var renamed = false
        defer {
            close(fd)
            if !renamed { unlink(temp) }
        }

        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let written = write(fd, base + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw posixError()
                }
                offset += written
            }
        }
        guard fchmod(fd, permissions) == 0 else { throw posixError() }
        if let group, fchown(fd, 0, group) != 0 { throw posixError() }
        // Flush before the rename, so a crash or power loss can't leave a renamed-but-empty file.
        guard fsync(fd) == 0 else { throw posixError() }
        guard rename(temp, url.path) == 0 else { throw posixError() }
        renamed = true
    }

    /// Reads a small regular file without following symlinks (or blocking on a FIFO).
    /// Returns nil if the file doesn't exist.
    public static func readRegularFile(_ url: URL, maxSize: Int = 64 * 1024) throws -> Data? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0 {
            if errno == ENOENT { return nil }
            throw errno == ELOOP ? AnchorStoreError.notRegularFile(path: url.path) : posixError()
        }
        defer { close(fd) }

        var info = stat()
        guard fstat(fd, &info) == 0 else { throw posixError() }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_size <= maxSize else {
            throw AnchorStoreError.notRegularFile(path: url.path)
        }

        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = read(fd, &chunk, chunk.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw posixError()
            }
            if count == 0 { break }
            data.append(chunk, count: count)
            if data.count > maxSize { throw AnchorStoreError.notRegularFile(path: url.path) }
        }
        return data
    }

    private static func posixError() -> Error {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case DecodingError.dataCorrupted: return "not valid JSON"
        case DecodingError.typeMismatch(_, let context), DecodingError.valueNotFound(_, let context):
            return "bad value for \(context.codingPath.map(\.stringValue).joined(separator: "."))"
        default: return error.localizedDescription
        }
    }
}
