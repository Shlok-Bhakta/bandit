import BandAccessibility
import BandKit
import BandLogging
import BandProtocol
import SwiftUI

/// "System Control": the band as an accessibility switch via Apple's BCI HID interface.
struct SystemControlView: View {
    @Environment(BandClient.self) private var band
    @Environment(AppModel.self) private var model

    var body: some View {
        let control = model.systemControl
        @Bindable var bindable = control
        List {
            Section {
                Button(role: .destructive) { control.emergencyStop() } label: {
                    Label("Emergency stop: release all, stop forwarding", systemImage: "stop.circle.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(Theme.danger)
                Toggle("Forward band gestures as BCI reports", isOn: $bindable.forwarding)
                Toggle("Also forward SIMULATED gestures", isOn: $bindable.acceptSimulated)
            } footer: {
                Text("Only real Neural Band gestures are forwarded unless you turn on simulated ones. To get out of Switch Control at any time, triple-click the side button (the Accessibility Shortcut), or ask Siri to “turn off Switch Control”.")
            }
            Section("Status") {
                InfoRow(label: "Wrist", value: band.wrist.wrist.title)
                InfoRow(label: "Band", value: band.phase.title)
                InfoRow(label: "BCI bridge", value: bridgeText(control.bridge.state))
                InfoRow(label: "HID transport", value: control.bridge.isReady ? "ESP32 BLE HID (BCI descriptor)" : "Preview only: reports are encoded and logged, not sent")
                InfoRow(label: "Switch Control", value: control.switchControlRunning ? "Running" : "Off")
                if let info = control.bridge.scanInfo {
                    InfoRow(label: "Scanning", value: "item \(info.selectedItem) of \(info.numberOfItems)\(info.itemControlType == 1 ? " (continuous)" : "")")
                }
                if let last = control.history.first {
                    InfoRow(label: "Last report", value: last.reports.map(\.description).joined(separator: "\n"), monospaced: true)
                }
                HStack {
                    Button(control.bridge.state == .off ? "Find ESP32 bridge" : "Stop bridge") {
                        control.bridge.state == .off ? control.bridge.start() : control.bridge.stop()
                    }
                }
            }
            Section {
                ForEach(RecognizedGesture.all, id: \.self) { gesture in
                    MappingRow(gesture: gesture, wrist: band.wrist.wrist)
                }
                Button("Restore default mapping") { control.restoreDefaultMapping(for: band.wrist.wrist) }
            } header: {
                Text("Mapping: \(band.wrist.wrist.title.lowercased())")
            } footer: {
                Text("Each wrist has its own mapping. Button numbers follow Apple's list order; Apple's descriptor fixes 0–3 (Select, Next, Previous, Menu), so the others are marked ⚠︎ until confirmed on a device.")
            }
            Section("Recent reports") {
                if control.history.isEmpty { Text("Nothing forwarded yet").foregroundStyle(.secondary) }
                ForEach(control.history) { sent in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text("\(sent.gesture.title) → \(sent.action.title)").font(.callout.weight(.semibold))
                            Spacer()
                            if sent.source != .band { SourceBadge(source: sent.source) }
                        }
                        Text(sent.reports.map(\.description).joined(separator: "  ")).font(.caption2.monospaced()).foregroundStyle(.secondary)
                        Text(sent.delivered ? "Sent to bridge" : "Preview (not sent)").font(.caption2).foregroundStyle(sent.delivered ? Theme.mint : .secondary)
                    }
                }
            }
            Section("Can an iPhone app do this alone?") {
                feasibility("Virtual HID device inside an iOS app", "Not supported", "The iOS 26.5 SDK has no CoreHID framework and no public IOHIDUserDevice headers. The symbols exist but are private, so App Store–compliant apps can't use them. This app doesn't use private APIs.", Theme.danger)
                feasibility("Apple's BCI HID interface", "Supported by iOS from a separate device", "Apple documents it for BCI hardware firmware talking to the iPhone as a HID device. An ESP32 can be that device.", Theme.mint)
                feasibility("ESP32 BLE HID bridge", "Firmware written, not yet tested", "See firmware/bci-bridge. Needs an ESP32, ESP32-C3, -C6 or -S3 (the ESP32-S2 has no Bluetooth).", Theme.warn)
                feasibility("App → bridge link while iOS owns the HID connection", "Not verified", "The bridge exposes a separate GATT service. Whether iOS lets apps use it on a system-owned HID connection needs a hardware test.", Theme.warn)
            }
            Section {
                Text("The Neural Band measures surface EMG, which is muscle activity, not brain activity. This feature uses Apple's BCI HID *interface* to deliver muscle-derived intent to Switch Control. It doesn't measure neural signals.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("System Control")
    }

    private func bridgeText(_ state: BCIBridgeClient.State) -> String {
        switch state {
        case .off: "Not started"
        case .searching: "Searching…"
        case .connecting: "Connecting…"
        case .ready(let name): "Ready: \(name)"
        case .failed(let message): "Failed: \(message)"
        }
    }

    private func feasibility(_ title: String, _ verdict: String, _ detail: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.callout.weight(.semibold))
                Spacer()
                Text(verdict).badgeStyle(color)
            }
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct MappingRow: View {
    let gesture: RecognizedGesture
    let wrist: Wrist
    @Environment(AppModel.self) private var model

    var body: some View {
        let control = model.systemControl
        let _ = control.mappingRevision
        let current = control.mapping(for: wrist).action(for: gesture)
        Picker(selection: Binding(get: { current }, set: { control.setAction($0, for: gesture, wrist: wrist) })) {
            Text("Nothing").tag(BCIAction?.none)
            ForEach(BCIAction.allCases) { action in
                Text("\(action.title) (\(action.buttonIndex))\(action.isDocumentedIndex ? "" : " ⚠︎")").tag(Optional(action))
            }
        } label: {
            Label(gesture.title, systemImage: Theme.symbol(for: gesture))
        }
    }
}
