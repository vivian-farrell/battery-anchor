import AnchorCore
import AppKit
import SwiftUI

/// The drop-down window: a large power button, max/buffer fields, and a one-line hint for whatever is hovered.
struct AnchorPanel: View {
    enum Field: Hashable {
        case max, buffer
    }

    enum Hint: Hashable {
        case battery, power, max, buffer, sleep, login
    }

    @EnvironmentObject private var model: AnchorModel

    @State private var maxText = ""
    @State private var bufferText = ""
    @State private var hovered: Hint?
    @State private var inputError: String?
    @FocusState private var focused: Field?

    private var enabled: Bool { model.config.enabled }

    var body: some View {
        VStack(spacing: 14) {
            header
            powerButton
            fields

            Toggle("Pause charging during sleep", isOn: Binding(
                get: { model.config.pauseChargingDuringSleep },
                set: { value in model.update { $0.pauseChargingDuringSleep = value } }
            ))
            .toggleStyle(.checkbox)
            .hint(.sleep, hintText(.sleep), $hovered)

            Divider()
            statusLine
            footer
        }
        .padding(16)
        .frame(width: 300)
        .onAppear {
            inputError = nil
            syncText()
            model.refreshLoginItem()
            // Don't open with a cursor in the first field.
            DispatchQueue.main.async { focused = nil }
        }
        .onDisappear {
            if let focused { commit(focused) }
        }
        .onChange(of: model.config) { _ in
            syncText()
        }
        .onChange(of: focused) { [focused] newValue in
            // Commit a field when focus leaves it (clicking elsewhere, Tab).
            if let previous = focused, previous != newValue { commit(previous) }
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack {
            Text("Battery Anchor").font(.headline)
            Spacer()
            Text(model.battery.map { "\($0.percent)%" } ?? "—")
                .font(.headline)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .hint(.battery, hintText(.battery), $hovered)
        }
    }

    private var powerButton: some View {
        VStack(spacing: 6) {
            Button(action: togglePower) {
                ZStack {
                    Circle()
                        .fill(enabled ? Color.green.opacity(0.15) : Color.secondary.opacity(0.08))
                    Circle()
                        .strokeBorder(enabled ? Color.green : Color.secondary.opacity(0.4), lineWidth: 3)
                    Image(systemName: "power")
                        .font(.system(size: 36, weight: .semibold))
                        .foregroundStyle(enabled ? Color.green : Color.secondary)
                }
                .frame(width: 88, height: 88)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Hold battery charge")
            .accessibilityValue(enabled ? "On" : "Off")
            .hint(.power, hintText(.power), $hovered)

            Text(enabled ? "On" : "Off")
                .font(.headline)
                .foregroundStyle(enabled ? .primary : .secondary)
        }
    }

    private var fields: some View {
        VStack(spacing: 8) {
            HStack(alignment: .top, spacing: 28) {
                numberField("Max charge", text: $maxText, field: .max)
                numberField("Buffer", text: $bufferText, field: .buffer)
            }
            Text("Charges again at \(model.config.rechargeLevel)%")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func numberField(_ title: String, text: Binding<String>, field: Field) -> some View {
        let hint: Hint = field == .max ? .max : .buffer
        return VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 4) {
                TextField(title, text: text)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(width: 56)
                    .focused($focused, equals: field)
                    .onSubmit { commit(field) }
                Text("%").foregroundStyle(.secondary)
            }
        }
        .hint(hint, hintText(hint), $hovered)
    }

    /// Shows the hovered control's explanation; otherwise any problem, otherwise what the daemon is doing.
    private var statusLine: some View {
        let message = statusMessage
        return Text(message.text)
            .font(.caption)
            .foregroundStyle(message.isWarning ? Color.orange : Color.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(message.text)
    }

    private var footer: some View {
        HStack {
            Toggle("Open at login", isOn: Binding(
                get: { model.launchAtLogin },
                set: { model.setLaunchAtLogin($0) }
            ))
            .toggleStyle(.checkbox)
            .hint(.login, hintText(.login), $hovered)
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .font(.caption)
    }

    // MARK: - Behaviour

    private var statusMessage: (text: String, isWarning: Bool) {
        if let hovered { return (hintText(hovered), false) }
        if let inputError { return (inputError, true) }
        if !model.daemonRunning { return ("Service not running — run make install", true) }
        if let error = model.configError ?? model.saveError ?? model.status?.error { return (error, true) }
        return (model.status?.reason ?? "", false)
    }

    private func hintText(_ hint: Hint) -> String {
        switch hint {
        case .battery:
            guard let battery = model.battery else { return "No battery found" }
            return battery.healthSummary.isEmpty ? "Current battery level" : battery.healthSummary
        case .power:
            return enabled ? "Turn off to let macOS charge normally" : "Hold the battery at max instead of 100%"
        case .max:
            return "Charge up to this level, then hold it there"
        case .buffer:
            return "Recharge once this far below max (default \(AnchorConfig.defaultRechargeBuffer)%)"
        case .sleep:
            return "Asleep, it stops just below max and finishes on wake"
        case .login:
            return "Open Battery Anchor when you log in"
        }
    }

    private func togglePower() {
        let next = !model.config.enabled
        model.update { $0.enabled = next }
    }

    private func commit(_ field: Field) {
        switch field {
        case .max:
            let range = AnchorConfig.maxChargeRange
            guard let value = parse(maxText), range.contains(value) else {
                inputError = "Max charge must be \(range.lowerBound)–\(range.upperBound)%"
                maxText = "\(model.config.maxCharge)"
                return
            }
            inputError = nil
            if value != model.config.maxCharge {
                model.update { $0.maxCharge = value }
            }
            maxText = "\(model.config.maxCharge)"

        case .buffer:
            let limit = AnchorConfig.maxRechargeBuffer(for: model.config.maxCharge)
            guard let value = parse(bufferText), (1...limit).contains(value) else {
                inputError = "Buffer must be 1–\(limit)% with a \(model.config.maxCharge)% max"
                bufferText = "\(model.config.rechargeBuffer)"
                return
            }
            inputError = nil
            if value != model.config.rechargeBuffer {
                model.update { $0.rechargeBuffer = value }
            }
            bufferText = "\(model.config.rechargeBuffer)"
        }
    }

    private func parse(_ text: String) -> Int? {
        Int(text.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces))
    }

    /// Mirrors saved settings into the fields, leaving a field alone while it's being edited.
    private func syncText() {
        if focused != .max { maxText = "\(model.config.maxCharge)" }
        if focused != .buffer { bufferText = "\(model.config.rechargeBuffer)" }
    }
}

private extension View {
    /// Shows `text` as a tooltip and reports hover so the panel's hint line can display it.
    func hint(_ hint: AnchorPanel.Hint, _ text: String, _ hovered: Binding<AnchorPanel.Hint?>) -> some View {
        help(text).onHover { inside in
            if inside {
                hovered.wrappedValue = hint
            } else if hovered.wrappedValue == hint {
                hovered.wrappedValue = nil
            }
        }
    }
}
