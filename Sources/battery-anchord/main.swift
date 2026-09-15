import AnchorCore
import Foundation
import IOKit
import IOKit.ps
import IOKit.pwr_mgt

// IOKit power messages (the iokit_common_msg macros aren't imported into Swift).
let kMsgCanSystemSleep: UInt32 = 0xE000_0270
let kMsgSystemWillSleep: UInt32 = 0xE000_0280
let kMsgSystemHasPoweredOn: UInt32 = 0xE000_0300

let adminGroup: gid_t = 80

/// Logging must never take the daemon down: raw write(2) with errors ignored, and a size cap.
enum Log {
    private static let formatter = ISO8601DateFormatter()
    private static let maxSize: off_t = 1 << 20
    private static var path: String?
    private static var fd: Int32 = STDERR_FILENO

    static func useFile(_ path: String) {
        self.path = path
        reopen()
    }

    static func write(_ message: String) {
        if path != nil { rotateIfNeeded() }
        let line = "\(formatter.string(from: Date())) \(message)\n"
        line.utf8CString.withUnsafeBufferPointer { buffer in
            _ = Darwin.write(fd, buffer.baseAddress, buffer.count - 1)
        }
    }

    private static func reopen() {
        guard let path else { return }
        let new = open(path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o644)
        var info = stat()
        // /Library/Logs is admin-writable: only append to a plain, singly linked file we own.
        guard new >= 0, fstat(new, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_nlink == 1, info.st_uid == getuid()
        else {
            if new >= 0 { close(new) }
            return
        }
        if fd != STDERR_FILENO { close(fd) }
        fd = new
    }

    private static func rotateIfNeeded() {
        guard let path else { return }
        guard fd != STDERR_FILENO else {
            reopen() // Opening failed earlier; try again.
            return
        }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_size > maxSize else { return }
        rename(path, path + ".1")
        reopen()
    }
}

func log(_ message: String) {
    Log.write(message)
}

final class Daemon {
    private let store: AnchorStore
    private var engine: AnchorEngine!

    private var lastConfigData: Data?
    private var lastWritten: AnchorStatus?
    private var lastWriteTime = Date.distantPast
    private var statusWriteError: String?
    private var pendingEvaluate: DispatchWorkItem?
    private var settingsWatch: DispatchSourceFileSystemObject?

    private var rootPort: io_connect_t = 0
    private var notifyPort: IONotificationPortRef?
    private var notifier: io_object_t = 0
    private var sources: [AnyObject] = []

    init(store: AnchorStore, actuator: ChargeActuator, makeActuator: (() throws -> ChargeActuator)?) {
        self.store = store
        engine = AnchorEngine(
            actuator: actuator,
            makeActuator: makeActuator,
            log: log,
            publish: { [unowned self] in publish($0) }
        )
    }

    func run() -> Never {
        log("battery-anchord starting (backend: \(engine.actuator.backendDescription), dir: \(store.directory.path))")
        prepareDirectories()

        let previous = store.loadStatus()
        let config: AnchorConfig
        if let loaded = readChangedConfig() {
            config = loaded
        } else if let previous {
            config = previous.config
            log("Using the last applied settings until config.json can be read")
        } else {
            config = AnchorConfig()
        }
        engine.start(config: config, previous: previous)
        logConfig(config)

        watchSettingsDirectory()
        watchPowerSources()
        watchSleep()
        watchSignals()

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + AnchorStore.statusInterval, repeating: AnchorStore.statusInterval, leeway: .seconds(5))
        timer.setEventHandler { [unowned self] in
            watchSettingsDirectory()
            evaluateNow("periodic")
        }
        timer.resume()
        sources.append(timer)

        evaluateNow("startup")
        CFRunLoopRun()
        exit(0)
    }

    // MARK: - Evaluation

    private func evaluateNow(_ trigger: String) {
        pendingEvaluate?.cancel()
        pendingEvaluate = nil
        reloadConfig()
        engine.evaluate(trigger)
    }

    /// Coalesces bursts of notifications (our own SMC writes also trigger power-source notifications).
    private func scheduleEvaluate(_ trigger: String, after delay: TimeInterval) {
        guard pendingEvaluate == nil else { return }
        let item = DispatchWorkItem { [unowned self] in
            pendingEvaluate = nil
            evaluateNow(trigger)
        }
        pendingEvaluate = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func publish(_ status: AnchorStatus) {
        if let lastWritten, !status.stopped {
            var comparable = status
            comparable.updatedAt = lastWritten.updatedAt
            // Skip identical rewrites, but refresh often enough for clients' liveness check.
            if comparable == lastWritten, Date().timeIntervalSince(lastWriteTime) < AnchorStore.statusInterval / 2 {
                return
            }
        }
        do {
            try store.writeStatus(status)
            lastWritten = status
            lastWriteTime = Date()
            statusWriteError = nil
        } catch {
            let message = "\(error)"
            if message != statusWriteError { log("ERROR writing status: \(message)") }
            statusWriteError = message
        }
    }

    // MARK: - Config

    private func prepareDirectories() {
        // Status lives in a root-only directory; settings in an admin-writable subdirectory.
        ensureDirectory(store.directory, mode: 0o755, group: 0)
        ensureDirectory(store.settingsDirectory, mode: 0o775, group: adminGroup)

        var info = stat()
        if lstat(store.configURL.path, &info) != 0, errno == ENOENT {
            do {
                try store.saveConfig(AnchorConfig(), group: getuid() == 0 ? adminGroup : nil)
            } catch {
                log("ERROR creating default config: \(error)")
            }
        }
    }

    private func ensureDirectory(_ url: URL, mode: mode_t, group: gid_t) {
        let path = url.path
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            log("ERROR creating \(path): \(error.localizedDescription)")
            return
        }
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
            log("ERROR \(path) is not a directory")
            return
        }
        guard getuid() == 0 else { return }
        // Safe by path: each parent is writable only by root, so these entries can't be swapped.
        lchown(path, 0, group)
        chmod(path, mode)
    }

    /// Returns config.json's contents if they changed since the last read and are valid.
    private func readChangedConfig() -> AnchorConfig? {
        let data: Data
        do {
            guard let read = try AnchorStore.readRegularFile(store.configURL) else { return nil }
            data = read
        } catch {
            setConfigError("Can't read \(store.configURL.path): \(error); keeping previous settings")
            return nil
        }
        guard data != lastConfigData else { return nil }
        lastConfigData = data

        do {
            let config = try store.decodeConfig(data)
            setConfigError(nil)
            return config
        } catch {
            setConfigError("\(error); keeping previous settings")
            return nil
        }
    }

    @discardableResult
    private func reloadConfig() -> Bool {
        guard let new = readChangedConfig() else { return false }
        let old = engine.machine.config
        engine.update(config: new)
        if new != old { logConfig(new) }
        return true
    }

    private func setConfigError(_ message: String?) {
        if let message, message != engine.configError { log("ERROR \(message)") }
        engine.configError = message
    }

    private func logConfig(_ config: AnchorConfig) {
        log("Config: enabled=\(config.enabled) max=\(config.maxCharge)% rechargeAt=\(config.rechargeLevel)% "
            + "pauseDuringSleep=\(config.pauseChargingDuringSleep)")
    }

    // MARK: - Event sources

    private func watchSettingsDirectory() {
        guard settingsWatch == nil else { return }
        // Clients replace config.json atomically, which modifies the directory. Status is written
        // elsewhere, so the daemon's own writes don't trigger this.
        let fd = open(store.settingsDirectory.path, O_EVTONLY)
        guard fd >= 0 else { return } // The periodic timer tries again.

        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [unowned self, weak source] in
            guard let source else { return }
            if !source.data.isDisjoint(with: [.delete, .rename]) {
                // The directory itself was removed or moved: watch whatever is at the path now.
                source.cancel()
                settingsWatch = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [unowned self] in watchSettingsDirectory() }
            }
            if reloadConfig() { scheduleEvaluate("config changed", after: 0.2) }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        settingsWatch = source
    }

    private func watchPowerSources() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let loop = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            Unmanaged<Daemon>.fromOpaque(context).takeUnretainedValue().powerSourceChanged()
        }, context)?.takeRetainedValue() else {
            log("WARN cannot subscribe to power source notifications")
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), loop, .defaultMode)
    }

    fileprivate func powerSourceChanged() {
        scheduleEvaluate("power source changed", after: 1)
    }

    private func watchSleep() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        rootPort = IORegisterForSystemPower(context, &notifyPort, { context, _, messageType, argument in
            guard let context else { return }
            Unmanaged<Daemon>.fromOpaque(context).takeUnretainedValue().handlePowerMessage(messageType, argument)
        }, &notifier)
        guard rootPort != 0, let notifyPort else {
            log("WARN cannot register for sleep notifications")
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(notifyPort).takeUnretainedValue(), .defaultMode)
    }

    fileprivate func handlePowerMessage(_ type: UInt32, _ argument: UnsafeMutableRawPointer?) {
        switch type {
        case kMsgCanSystemSleep:
            IOAllowPowerChange(rootPort, Int(bitPattern: argument))
        case kMsgSystemWillSleep:
            pendingEvaluate?.cancel()
            pendingEvaluate = nil
            reloadConfig()
            engine.willSleep()
            IOAllowPowerChange(rootPort, Int(bitPattern: argument))
        case kMsgSystemHasPoweredOn:
            // Also sent for dark wakes; the engine checks system capabilities before acting as if awake.
            pendingEvaluate?.cancel()
            pendingEvaluate = nil
            reloadConfig()
            engine.didWake()
        default:
            break
        }
    }

    private func watchSignals() {
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [unowned self] in
                engine.shutdown()
                exit(0)
            }
            source.resume()
            sources.append(source)
        }
        signal(SIGHUP, SIG_IGN)
        let hup = DispatchSource.makeSignalSource(signal: SIGHUP, queue: .main)
        hup.setEventHandler { [unowned self] in
            lastConfigData = nil
            evaluateNow("SIGHUP")
        }
        hup.resume()
        sources.append(hup)
    }
}

// MARK: - Entry point

let arguments = Array(CommandLine.arguments.dropFirst())

if arguments.contains("--help") || arguments.contains("-h") {
    print("""
    usage: battery-anchord [--dry-run] [--log-file PATH] [--restore]

      (no args)        Run the charge-control daemon (requires root; normally started by launchd)
      --dry-run        Run the control loop without writing to the SMC
      --log-file PATH  Append log lines to PATH (rotated at 1 MB) instead of stderr
      --restore        Re-enable charging and the power adapter, then exit
    """)
    exit(0)
}

if arguments.contains("--restore") {
    func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("battery-anchord: \(message)\n".utf8))
        exit(1)
    }
    let controller: SMCChargeController
    do {
        controller = try SMCChargeController()
    } catch {
        fail("\(error)")
    }
    let errors = controller.restoreDefaults()
    guard errors.isEmpty else { fail(errors.map { "\($0)" }.joined(separator: "; ")) }
    let state = controller.readState()
    guard state.chargingInhibited == false, state.dischargeForced == false else {
        fail("charge settings didn't read back as normal after restoring")
    }
    print("Charging restored")
    exit(0)
}

if let index = arguments.firstIndex(of: "--log-file"), index + 1 < arguments.count {
    Log.useFile(arguments[index + 1])
}

let actuator: ChargeActuator
let makeActuator: (() throws -> ChargeActuator)?
if arguments.contains("--dry-run") {
    actuator = DryRunChargeController()
    makeActuator = nil
} else {
    if getuid() != 0 {
        log("WARN not running as root; SMC writes will fail (use --dry-run to test)")
    }
    makeActuator = { try SMCChargeController() }
    do {
        actuator = try SMCChargeController()
    } catch {
        // Stay up, report the problem and retry: exiting would make launchd restart us in a loop.
        log("ERROR charge control unavailable: \(error); retrying every 30 s")
        actuator = UnavailableChargeController(error: error)
    }
}

Daemon(store: AnchorStore(), actuator: actuator, makeActuator: makeActuator).run()
