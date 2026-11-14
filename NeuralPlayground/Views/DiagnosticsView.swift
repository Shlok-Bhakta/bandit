import BandCredentials
import BandKit
import BandLogging
import BandProtocol
import BandTransport
import SwiftUI

struct DiagnosticsView: View {
    @Environment(BandClient.self) private var band
    @State private var verboseFrames = BandLog.shared.logsFrames
    @State private var copied = false

    var body: some View {
        let d = band.diagnostics
        List {
            Section {
                NavigationLink { LogsView() } label: { Label("Logs", systemImage: "doc.text.magnifyingglass") }
                NavigationLink { FirmwareView() } label: { Label("Firmware updates", systemImage: "arrow.down.circle.dotted") }
                Button {
                    SecureClipboard.copy(BandLog.shared.export(header: AppModel.reportHeader))
                    copied = true
                } label: { Label(copied ? "Full log copied" : "Copy full log", systemImage: copied ? "checkmark" : "doc.on.doc") }
                ShareLink(item: DiagnosticReport.make(band), preview: SharePreview("neural-playground-diagnostics.txt")) {
                    Label("Share sanitized diagnostic report", systemImage: "square.and.arrow.up")
                }
                Toggle("Log every frame header (verbose)", isOn: $verboseFrames)
                    .onChange(of: verboseFrames) { _, on in
                        BandLog.shared.logsFrames = on
                        logNotice(.app, "Verbose frame logging \(on ? "on (applies from the next connection)" : "off")")
                    }
                Toggle("Auto-reconnect", isOn: Binding(get: { band.autoReconnect }, set: { band.autoReconnect = $0 }))
            } footer: {
                Text("Logs and reports never contain owner keys, Meta tokens, receipts or sensor payloads. Serial numbers are masked.")
            }

            Section("Bluetooth") {
                InfoRow(label: "Adapter", value: band.bluetoothState)
                InfoRow(label: "Phase", value: band.phase.title)
                InfoRow(label: "Peripheral", value: d.peripheralName ?? "—")
                InfoRow(label: "iOS identifier", value: d.peripheralID?.uuidString ?? "—", monospaced: true)
                InfoRow(label: "RSSI", value: band.rssi.map { "\($0) dBm" } ?? "—")
                InfoRow(label: "Max write", value: d.maxWriteLength.map { "\($0) B" } ?? "—")
                InfoRow(label: "Connect attempts", value: "\(d.connectAttempts)")
                InfoRow(label: "Reconnects", value: "\(d.reconnects)")
            }
            Section("L2CAP") {
                InfoRow(label: "PSM", value: d.psm.map(String.init) ?? "—")
                InfoRow(label: "Opened", value: d.l2capOpenedAt?.formatted(date: .omitted, time: .standard) ?? "—")
                InfoRow(label: "Bytes in / out", value: "\(d.bytesIn) / \(d.bytesOut)")
                InfoRow(label: "Time to streaming", value: d.timeToStreaming.map { String(format: "%.2f s", $0) } ?? "—")
            }
            Section("Protocol") {
                InfoRow(label: "Session stage", value: d.sessionStage)
                InfoRow(label: "Encryption", value: d.peerParameters.map { "band scheme \($0)" + (d.newerFirmwareScheme ? ", guess \(d.schemeGuess ?? 0)" : " (scheme 3)") } ?? "—")
                InfoRow(label: "Authenticated packets", value: "\(d.authenticatedPackets)")
                InfoRow(label: "Frames decoded", value: "\(d.framesDecoded)")
                InfoRow(label: "Decoding failures", value: "\(d.decodeFailures)")
                InfoRow(label: "Skipped transport records", value: "\(d.skippedTransportRecords)")
                if !d.unknownKinds.isEmpty {
                    InfoRow(label: "Unhandled kinds", value: d.unknownKinds.sorted { $0.key < $1.key }.map { "\($0.key)×\($0.value)" }.joined(separator: " "), monospaced: true)
                }
            }
            Section("Ownership") {
                InfoRow(label: "Mode", value: d.ownershipMode)
                InfoRow(label: "Owner fingerprint", value: d.ownerFingerprint ?? band.ownerFingerprint ?? "—", monospaced: true)
                InfoRow(label: "Band proof verified", value: d.bandVerified ? "yes" : "no (no band key from Meta)")
                InfoRow(label: "Pending key", value: band.hasPendingKey ? "present" : "none")
                InfoRow(label: "Meta session", value: band.hasMetaSession ? "saved" : "none")
            }
            Section("Device") {
                InfoRow(label: "Firmware", value: band.deviceInfo?.firmware ?? "—")
                InfoRow(label: "Software", value: band.deviceInfo?.software ?? "—")
                InfoRow(label: "Hardware", value: band.deviceInfo?.hardware ?? "—")
                InfoRow(label: "EMG model", value: band.deviceInfo?.model ?? "—")
                if let models = band.deviceInfo?.models, !models.isEmpty { InfoRow(label: "All models", value: models.joined(separator: ", ")) }
                InfoRow(label: "Handwriting model", value: band.deviceInfo.map { $0.hasHandwritingModel ? "present" : "absent" } ?? "—")
                InfoRow(label: "Hand", value: band.hand?.rawValue ?? "—")
                ForEach(d.deviceInformation.sorted { $0.key < $1.key }, id: \.key) { InfoRow(label: $0.key, value: $0.value) }
            }
            Section("Streams") {
                InfoRow(label: "Gesture messages", value: "\(d.gestureMessages)")
                InfoRow(label: "Recognized gestures", value: "\(d.recognizedGestures)")
                InfoRow(label: "Gyro samples", value: "\(d.motionMessages)")
                InfoRow(label: "Orientation samples", value: "\(d.orientationMessages)")
                InfoRow(label: "Raw EMG batches", value: "\(d.emgFrames)")
                InfoRow(label: "Haptics sent / acknowledged", value: "\(d.hapticsSent) / \(d.hapticsAcknowledged)")
            }
            Section("Gesture timing") {
                InfoRow(label: "Decode → dispatch", value: d.lastGestureDispatchMs.map { String(format: "%.2f ms", $0) } ?? "—")
                if !d.gestureIntervals.isEmpty {
                    let sorted = d.gestureIntervals.sorted()
                    InfoRow(label: "Interval min / median", value: String(format: "%.0f / %.0f ms", sorted.first! * 1000, sorted[sorted.count / 2] * 1000))
                }
            }
            Section("GATT") {
                if d.gatt.isEmpty { Text("Not discovered yet").foregroundStyle(.secondary) }
                ForEach(d.gatt) { service in
                    DisclosureGroup {
                        ForEach(service.characteristics) { characteristic in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(characteristic.uuid).font(.caption.monospaced())
                                Text(characteristic.properties.joined(separator: ", ")).font(.caption2).foregroundStyle(.secondary)
                                if let value = characteristic.value { Text(value).font(.caption2) }
                            }
                        }
                    } label: {
                        Text(service.uuid).font(.callout.monospaced()) + Text(service.uuid == "FEB8" ? "  Meta band service" : "").font(.caption).foregroundColor(.secondary)
                    }
                }
            }
            Section("Errors") {
                if d.errors.isEmpty { Text("None").foregroundStyle(.secondary) }
                ForEach(Array(d.errors.reversed().enumerated()), id: \.offset) { _, error in
                    VStack(alignment: .leading) {
                        Text(error.date.formatted(date: .omitted, time: .standard)).font(.caption2).foregroundStyle(.secondary)
                        Text(error.message).font(.caption)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .screenBackground()
        .navigationTitle("Diagnostics")
    }
}

/// Plain-text report built only from non-secret fields.
@MainActor
enum DiagnosticReport {
    static func make(_ band: BandClient) -> String {
        let d = band.diagnostics
        var lines = [AppModel.reportHeader, "", "== Connection"]
        lines.append("Bluetooth: \(band.bluetoothState); phase: \(band.phase.title)")
        lines.append("Peripheral: \(d.peripheralName ?? "-") \(d.peripheralID?.uuidString ?? "-")")
        lines.append("RSSI: \(band.rssi.map(String.init) ?? "-"); PSM \(d.psm.map(String.init) ?? "-"); max write \(d.maxWriteLength.map(String.init) ?? "-")")
        lines.append("Attempts \(d.connectAttempts), reconnects \(d.reconnects), time to streaming \(d.timeToStreaming.map { String(format: "%.2fs", $0) } ?? "-")")
        lines.append("Bytes in/out \(d.bytesIn)/\(d.bytesOut)")
        lines += ["", "== Protocol"]
        lines.append("Stage \(d.sessionStage); band scheme \(d.peerParameters.map(String.init) ?? "-"); newer firmware \(d.newerFirmwareScheme); guess \(d.schemeGuess.map(String.init) ?? "-")")
        lines.append("Packets \(d.authenticatedPackets), frames \(d.framesDecoded), decode failures \(d.decodeFailures), skipped records \(d.skippedTransportRecords)")
        lines.append("Unhandled kinds: \(d.unknownKinds.sorted { $0.key < $1.key }.map { "\($0.key)x\($0.value)" }.joined(separator: " "))")
        lines += ["", "== Ownership"]
        lines.append("Mode: \(d.ownershipMode); fingerprint \(band.ownerFingerprint ?? "-"); band verified \(d.bandVerified); pending key \(band.hasPendingKey); meta session \(band.hasMetaSession)")
        if let stored = band.storedBand {
            lines.append("Stored band: \(stored.name), origin \(stored.origin.rawValue), scheme guess \(stored.schemeGuess.map(String.init) ?? "-"), address \(stored.address == nil ? "not set" : "set"), serial \(stored.serial.map { BandLog.mask($0) } ?? "-")")
        }
        lines += ["", "== Device"]
        if let info = band.deviceInfo {
            lines.append("Firmware \(info.firmware), software \(info.software), hardware \(info.hardware), model \(info.model), models \(info.models.joined(separator: ","))")
        }
        lines.append("Device Information: \(d.deviceInformation.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "; "))")
        lines.append("Battery \(band.battery.map(String.init) ?? "-")%, charging \(band.charging.map(String.init) ?? "-"), hand \(band.hand?.rawValue ?? "-")")
        lines += ["", "== Streams"]
        lines.append("Gestures \(d.gestureMessages) (recognized \(d.recognizedGestures)), gyro \(d.motionMessages), orientation \(d.orientationMessages), EMG \(d.emgFrames)")
        lines.append("Haptics sent \(d.hapticsSent), acknowledged \(d.hapticsAcknowledged)")
        lines.append("EMG config: \(band.emgConfig.map { "\($0.channels)ch \($0.sampleRate)Hz \($0.adcBits)bit enc\($0.encoding)" } ?? "-"); error: \(band.emgError ?? "-")")
        lines += ["", "== GATT"]
        for service in d.gatt {
            lines.append("\(service.uuid)")
            for characteristic in service.characteristics {
                lines.append("  \(characteristic.uuid) [\(characteristic.properties.joined(separator: ","))]\(characteristic.value.map { " = \($0)" } ?? "")")
            }
        }
        lines += ["", "== Errors"]
        for error in d.errors { lines.append("\(ISO8601DateFormatter().string(from: error.date)) \(error.message)") }
        lines += ["", "== Log (info and above, last 400 lines)"]
        let log = BandLog.shared.snapshot().filter { $0.level >= .info }.suffix(400).map(\.line)
        lines.append(contentsOf: log)
        return lines.joined(separator: "\n") + "\n"
    }
}

struct LogsView: View {
    @State private var entries: [BandLog.Entry] = []
    @State private var minimum = BandLog.Level.info
    @State private var category: BandLog.Category?
    @State private var search = ""
    @State private var follow = true
    @State private var copied: String?
    @State private var revision = -1

    private var filtered: [BandLog.Entry] {
        entries.filter { entry in
            entry.level >= minimum && (category == nil || entry.category == category)
                && (search.isEmpty || entry.message.localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                Section {
                    Picker("Level", selection: $minimum) {
                        ForEach(BandLog.Level.allCases, id: \.self) { Text($0.tag.trimmingCharacters(in: .whitespaces)).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Picker("Category", selection: $category) {
                        Text("All").tag(BandLog.Category?.none)
                        ForEach(BandLog.Category.allCases, id: \.self) { Text($0.rawValue).tag(Optional($0)) }
                    }
                    Toggle("Follow newest", isOn: $follow)
                }
                Section("\(filtered.count) of \(entries.count) entries") {
                    ForEach(filtered) { entry in
                        Text(entry.line)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(color(entry.level))
                            .textSelection(.enabled)
                            .listRowInsets(EdgeInsets(top: 2, leading: 10, bottom: 2, trailing: 10))
                            .id(entry.id)
                    }
                }
            }
            .listStyle(.plain)
            .searchable(text: $search, prompt: "Filter messages")
            .onChange(of: entries.count) { _, _ in
                if follow, let last = filtered.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
        .navigationTitle("Logs")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    Button("Copy all (\(entries.count) lines)") { copy(BandLog.shared.export(header: AppModel.reportHeader), "All lines copied") }
                    Button("Copy filtered") { copy(AppModel.reportHeader + "\n" + filtered.map(\.line).joined(separator: "\n"), "Filtered lines copied") }
                    Button("Copy last 300") { copy(AppModel.reportHeader + "\n" + entries.suffix(300).map(\.line).joined(separator: "\n"), "Last 300 copied") }
                    Divider()
                    Button("Clear", role: .destructive) { BandLog.shared.clear() }
                } label: { Image(systemName: "doc.on.doc") }
                ShareLink(item: BandLog.shared.export(header: AppModel.reportHeader), preview: SharePreview("neural-playground.log")) {
                    Image(systemName: "square.and.arrow.up")
                }
            }
        }
        .overlay(alignment: .bottom) {
            if let copied {
                Text(copied).font(.callout).padding(10).background(.ultraThinMaterial, in: Capsule()).padding()
                    .task { try? await Task.sleep(for: .seconds(2)); self.copied = nil }
            }
        }
        .task {
            while !Task.isCancelled {
                if BandLog.shared.revision != revision {
                    revision = BandLog.shared.revision
                    entries = BandLog.shared.snapshot()
                }
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
    }

    private func copy(_ text: String, _ note: String) {
        SecureClipboard.copy(text)
        copied = note
    }

    private func color(_ level: BandLog.Level) -> Color {
        switch level {
        case .debug: .secondary
        case .info: .primary
        case .notice: Theme.accent
        case .warning: Theme.warn
        case .error: Theme.danger
        }
    }
}
