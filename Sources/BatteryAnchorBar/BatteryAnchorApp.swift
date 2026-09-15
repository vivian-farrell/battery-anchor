import AnchorCore
import AppKit
import IOKit.ps
import ServiceManagement
import SwiftUI

@main
struct BatteryAnchorApp: App {
    @StateObject private var model = AnchorModel()

    init() {
        // Used by uninstall.sh, which can't remove a per-user login item itself.
        if CommandLine.arguments.contains("--unregister-login-item") {
            do {
                try SMAppService.mainApp.unregister()
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("Couldn't remove login item: \(error.localizedDescription)\n".utf8))
                exit(1)
            }
        }
    }

    var body: some Scene {
        MenuBarExtra {
            AnchorPanel()
                .environmentObject(model)
        } label: {
            Image(nsImage: model.statusImage)
                .renderingMode(.template)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AnchorModel: ObservableObject {
    @Published private(set) var status: AnchorStatus?
    @Published private(set) var battery: BatterySnapshot?
    @Published private(set) var config = AnchorConfig()
    @Published private(set) var daemonRunning = false
    @Published private(set) var configError: String?
    @Published private(set) var saveError: String?
    @Published private(set) var launchAtLogin = false

    private let store = AnchorStore()
    private var sources: [DispatchSourceProtocol] = []
    private var watchedPaths = Set<String>()

    init() {
        refreshBattery()
        refreshFiles()
        watchPowerSources()
        watchDirectories()

        // Event-driven otherwise; this catches a daemon that died without a final status write,
        // and starts the directory watches once Battery Anchor is installed.
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 15, repeating: 15, leeway: .seconds(5))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.watchDirectories()
                self?.refreshFiles()
            }
        }
        timer.resume()
        sources.append(timer)

        #if DEBUG
        DispatchQueue.main.async { PanelPreview.showIfRequested(model: self) }
        #endif
    }

    /// Anchor when the limit is on, battery with a bolt when off, warning if the service isn't running.
    var statusImage: NSImage {
        guard daemonRunning else { return StatusIcons.warning }
        return config.enabled ? StatusIcons.anchor : StatusIcons.batteryBolt
    }

    func refreshBattery() {
        assign(\.battery, BatteryInfo.read())
    }

    func refreshFiles() {
        let status = store.loadStatus()
        assign(\.status, status)
        assign(\.daemonRunning, status.map { AnchorStore.isDaemonAlive($0) } ?? false)
        do {
            if let loaded = try store.readConfig() { assign(\.config, loaded) }
            assign(\.configError, nil)
        } catch {
            assign(\.configError, "\(error)")
        }
    }

    func refreshLoginItem() {
        assign(\.launchAtLogin, SMAppService.mainApp.status == .enabled)
    }

    func update(_ change: (inout AnchorConfig) -> Void) {
        do {
            assign(\.config, try store.updateConfig(change))
            assign(\.saveError, nil)
        } catch {
            assign(\.saveError, "Couldn't save settings: \(error.localizedDescription)")
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            assign(\.saveError, "Couldn't change login item: \(error.localizedDescription)")
        }
        refreshLoginItem()
    }

    /// Only publishes real changes, so unchanged refreshes don't re-render the menu bar.
    private func assign<T: Equatable>(_ keyPath: ReferenceWritableKeyPath<AnchorModel, T>, _ value: T) {
        if self[keyPath: keyPath] != value {
            self[keyPath: keyPath] = value
        }
    }

    private func watchPowerSources() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let model = Unmanaged<AnchorModel>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { model.refreshBattery() }
        }, context)?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }

    /// Watches the status and settings directories; files inside are replaced atomically.
    private func watchDirectories() {
        for url in [store.directory, store.settingsDirectory] where !watchedPaths.contains(url.path) {
            let path = url.path
            let fd = open(path, O_EVTONLY)
            guard fd >= 0 else { continue } // Not installed yet; the timer retries.

            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
            source.setEventHandler { [weak self, weak source] in
                MainActor.assumeIsolated {
                    guard let self, let source else { return }
                    if !source.data.isDisjoint(with: [.delete, .rename]) {
                        // Directory removed (uninstall); drop the watch so the timer can re-establish it.
                        source.cancel()
                        self.watchedPaths.remove(path)
                    }
                    self.refreshFiles()
                }
            }
            source.setCancelHandler { close(fd) }
            source.resume()
            sources.append(source)
            watchedPaths.insert(path)
        }
    }
}

#if DEBUG
/// `BATTERY_ANCHOR_PREVIEW=1 .build/debug/BatteryAnchorBar` also shows the panel in a normal window,
/// so it can be inspected or screenshotted without clicking the status item.
@MainActor
enum PanelPreview {
    private static var window: NSWindow?

    static func showIfRequested(model: AnchorModel) {
        guard ProcessInfo.processInfo.environment["BATTERY_ANCHOR_PREVIEW"] != nil else { return }
        let host = NSHostingView(rootView: AnchorPanel().environmentObject(model))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Battery Anchor preview"
        window.contentView = host
        let screen = NSScreen.screens[0].frame
        window.setFrameTopLeftPoint(NSPoint(x: 120, y: screen.maxY - 120))
        // An unbundled executable can't show windows until it has an activation policy.
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        self.window = window

        print("PREVIEW_WINDOW \(window.windowNumber)")
        fflush(stdout)
    }
}
#endif
