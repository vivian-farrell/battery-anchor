import AnchorCore
import Foundation

let store = AnchorStore()

let usage = """
usage: battery-anchor <command>

  status [--json]      Show battery and charge-control state (default)
  on [MAX]             Charge to MAX% (default: current setting) and hold there
  off                  Charge normally
  max PERCENT          Set the maximum charge (\(AnchorConfig.maxChargeRange.lowerBound)–\(AnchorConfig.maxChargeRange.upperBound))
  buffer POINTS        Start charging again once the battery is POINTS below the max (default \(AnchorConfig.defaultRechargeBuffer))
  sleep-pause on|off   While asleep, stop charging just below the max (finishes on wake)
  smc                  Show charge-control SMC keys (diagnostics)
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("battery-anchor: \(message)\n".utf8))
    exit(1)
}

func parseNumber(_ text: String?, in range: ClosedRange<Int>, _ what: String) -> Int {
    guard let text else { fail("missing \(what)\n\n\(usage)") }
    let trimmed = text.hasSuffix("%") ? String(text.dropLast()) : text
    guard let value = Int(trimmed), range.contains(value) else {
        fail("\(what) must be between \(range.lowerBound) and \(range.upperBound)")
    }
    return value
}

func parseSwitch(_ text: String?) -> Bool {
    switch text?.lowercased() {
    case "on", "true", "yes", "1": return true
    case "off", "false", "no", "0": return false
    default: fail("expected 'on' or 'off'")
    }
}

func updateConfig(_ change: (inout AnchorConfig) -> Void) {
    let saved: AnchorConfig
    do {
        saved = try store.updateConfig(change)
    } catch let error as AnchorStoreError {
        fail("\(error)")
    } catch {
        fail("couldn't write \(store.configURL.path): \(error.localizedDescription)\n"
            + "Is Battery Anchor installed (make install), and is this an admin account?")
    }

    // Give the daemon a moment to pick up the change so the status we print reflects it.
    let deadline = Date().addingTimeInterval(3)
    while Date() < deadline {
        if let status = store.loadStatus(), status.config == saved, AnchorStore.isDaemonAlive(status) { break }
        usleep(150_000)
    }
    printStatus()
}

func printStatus() {
    let status = store.loadStatus()
    let alive = status.map { AnchorStore.isDaemonAlive($0) } ?? false
    let battery = BatteryInfo.read()

    func row(_ label: String, _ value: String) {
        print(label.padding(toLength: 10, withPad: " ", startingAt: 0) + value)
    }

    if let battery {
        let bypassed = alive && status?.dischargeForced == true
        row("Battery", "\(battery.percent)% · \(battery.powerDescription(adapterBypassed: bypassed))")
    } else {
        row("Battery", "no internal battery found")
    }

    do {
        let config = try store.readConfig() ?? status?.config ?? AnchorConfig()
        row("Anchor", "\(config.summary)  (sleep-pause \(config.pauseChargingDuringSleep ? "on" : "off"))")
    } catch {
        row("Anchor", "unknown — \(error)")
    }

    if let status, alive {
        row("State", status.reason)
        row("Service", "running (pid \(status.daemonPID), \(status.backend))")
        if let error = status.error { row("Error", error) }
    } else if let status, status.stopped {
        row("Service", "STOPPED — \(status.reason). Start it with `make install`.")
        if status.controlling {
            row("Warning", "charge settings may still be limited; run `sudo battery-anchord --restore` or reinstall")
        }
        if let error = status.error { row("Error", error) }
    } else {
        row("Service", "NOT RUNNING — the charge limit is not enforced. Install with `make install`.")
    }

    if let summary = battery?.healthSummary, !summary.isEmpty {
        row("Health", summary)
    }
}

let args = Array(CommandLine.arguments.dropFirst())
let command = args.first ?? "status"
let argument = args.dropFirst().first

switch command {
case "status":
    if argument == "--json" {
        guard let status = store.loadStatus() else { fail("no status available; is the daemon running?") }
        print(String(decoding: try! AnchorJSON.encoder.encode(status), as: UTF8.self))
    } else {
        printStatus()
    }

case "on":
    let maxCharge = argument.map { parseNumber($0, in: AnchorConfig.maxChargeRange, "max charge") }
    updateConfig {
        $0.enabled = true
        if let maxCharge { $0.maxCharge = maxCharge }
    }

case "off":
    updateConfig { $0.enabled = false }

case "max":
    let maxCharge = parseNumber(argument, in: AnchorConfig.maxChargeRange, "max charge")
    updateConfig { $0.maxCharge = maxCharge }

case "buffer":
    updateConfig {
        let limit = AnchorConfig.maxRechargeBuffer(for: $0.maxCharge)
        $0.rechargeBuffer = parseNumber(argument, in: 1...limit, "buffer (with max \($0.maxCharge)%)")
    }

case "sleep-pause":
    let on = parseSwitch(argument)
    updateConfig { $0.pauseChargingDuringSleep = on }

case "smc":
    do {
        let smc = try SMC()
        for key in ["CHTE", "CH0B", "CH0C", "CHIE", "CH0I", "CH0J", "BCLM"] {
            let value = (try? smc.read(key)).map { $0.map { String(format: "%02x", $0) }.joined() } ?? "—"
            print("\(key)  \(value)")
        }
        print("\nBackend: \(try SMCChargeController().backendDescription)")
    } catch {
        fail("\(error)")
    }

case "help", "-h", "--help":
    print(usage)

default:
    FileHandle.standardError.write(Data("battery-anchor: unknown command '\(command)'\n\n\(usage)\n".utf8))
    exit(1)
}
