import BandKit
import BandLogging
import BandProtocol
import SwiftUI

/// Everything the band exposes, in one place: a demo for each capability, the device and update
/// status, every setting and config field (read only), experimental streams, every message type the
/// band sends, and its firmware log.
struct BandExplorerView: View {
    @Environment(BandClient.self) private var band
    @State private var customField = ""
    @State private var outputs: [UInt64: InferenceSample] = [:]
    @State private var outputCounts: [UInt64: Int] = [:]
    @State private var settingFilter = ""

    private var connected: Bool { band.phase == .streaming }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                if !connected {
                    Label("Connect your band on the Band tab to explore it.", systemImage: "info.circle")
                        .font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                }
                capabilities
                device
                survey
                streams
                messages
                if !band.firmwareLog.isEmpty { firmwareLog }
            }
            .padding()
        }
        .screenBackground()
        .navigationTitle("Band Explorer")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { ConnectionPill() } }
        .onDisappear { if !band.probeRequested.isEmpty { band.setProbeStreams([]) } }
        .task {
            for await event in band.events.subscribe(buffer: 2048) {
                guard case .inference(let sample) = event else { continue }
                outputs[sample.pipeline] = sample
                outputCounts[sample.pipeline, default: 0] += 1
            }
        }
    }

    // MARK: capabilities

    private var capabilities: some View {
        Card(title: "What the band can do", systemImage: "sparkles") {
            capability("Finger gestures", "Index and middle taps, double taps and holds; thumb swipes in four directions", count: band.diagnostics.gestureMessages) { EventLogView() }
            capability("Pinch dial", "Hold an index pinch and turn your wrist: the band reports the rotation", count: nil) { SafeCrackerView() }
            capability("Orientation", "A quaternion of your forearm about 50 times a second", count: band.diagnostics.orientationMessages) { CursorLabView() }
            capability("Wrist twist", "Roll around your forearm, computed from orientation", count: nil) { PongView() }
            capability("Gyroscope", "Raw angular velocity on three axes", count: band.diagnostics.motionMessages) { SignalsView() }
            capability("Raw EMG", emgDetail, count: band.diagnostics.emgFrames) { EMGView() }
            capability("Haptics", "Vibration with a duration and strength, plus built-in patterns", count: band.diagnostics.hapticsSent) { HapticsView() }
            capability("Handwriting model", band.deviceInfo.map { $0.hasHandwritingModel ? "On-device letter recognition: this band has the model" : "On-device letter recognition: no hw_ model listed" } ?? "On-device letter recognition", count: nil) { HandwritingView() }
            capability("Hand setting", "Which wrist the band thinks it's on (\(band.hand?.rawValue ?? "unknown"))", count: nil) { WristView() }
            HStack {
                Text("Battery").font(.callout.weight(.semibold))
                Spacer()
                Text(band.battery.map { "\($0)%\(band.charging == true ? " · charging" : "")" } ?? "—").font(.callout.monospacedDigit())
            }
        }
    }

    private var emgDetail: String {
        if let config = band.emgConfig {
            return "\(config.channels) channels × \(config.sampleRate) Hz, \(config.adcBits)-bit"
        }
        return "8 channels of muscle signal at 2 kHz"
    }

    private func capability<Destination: View>(_ title: String, _ detail: String, count: Int?, @ViewBuilder destination: () -> Destination) -> some View {
        NavigationLink(destination: destination) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.callout.weight(.semibold))
                    Text(detail).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                }
                Spacer()
                if let count, count > 0 { Text("\(count)").font(.caption.monospacedDigit()).foregroundStyle(Theme.mint) }
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: device

    private var device: some View {
        Card(title: "Device", systemImage: "cpu") {
            NavigationLink { FirmwareView() } label: {
                HStack {
                    Label("Firmware updates", systemImage: "arrow.down.circle.dotted").font(.callout.weight(.semibold))
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if let info = band.deviceInfo {
                row("Firmware", info.firmware)
                if !info.software.isEmpty { row("Software", info.software) }
                row("Hardware", info.hardware)
                if !info.releaseBranch.isEmpty { row("Release", info.releaseBranch) }
                row("Running model", info.model)
                if !info.models.isEmpty {
                    Text("Models on the band").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(info.models, id: \.self) { model in
                        HStack {
                            Text(model).font(.caption.monospaced())
                            Spacer()
                            Text(modelKind(model)).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                Text("Not reported yet.").foregroundStyle(.secondary).font(.callout)
            }
            if let ota = band.survey.ota {
                Divider()
                row("Update service", ota.stateName)
                row("Firmware state", ota.deviceName)
                if let reason = ota.reasonName { row("Unavailable because", reason) }
                row("Firmware version", ota.activeFirmware.map(String.init) ?? "—")
                if let staged = ota.stagedFirmware { row("Staged firmware", String(staged)) }
                row("ML bundle version", ota.mlModel.map(String.init) ?? "—")
                Text("Read only: the app never starts, stages or commits an update.").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func modelKind(_ id: String) -> String {
        if id.hasPrefix("hw_") { return "handwriting" }
        if id.hasPrefix("cc_") { return "gestures" }
        if id.hasPrefix("ia_") { return "wake (standby)" }
        if id.hasPrefix("pc_") { return "classifier" }
        return ""
    }

    // MARK: survey

    private var survey: some View {
        Card(title: "Settings and config (read only)", systemImage: "list.bullet.rectangle.portrait") {
            HStack {
                Button {
                    band.startSurvey()
                } label: {
                    Label(band.survey.phase == .running ? "Reading…" : band.survey.settingsCount != nil ? "Read again" : "Read everything",
                          systemImage: "magnifyingglass").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!connected || band.survey.phase == .running || band.handwriting.active)
            }
            if !band.survey.message.isEmpty { Text(band.survey.message).font(.caption).foregroundStyle(.secondary) }
            ForEach(band.survey.problems, id: \.self) { Text($0).font(.caption).foregroundStyle(Theme.warn) }
            Text("Asks the band to list and read each of its settings, its whole config and its update status. Only read requests are sent.")
                .font(.caption2).foregroundStyle(.secondary)
            if let count = band.survey.settingsCount {
                Divider()
                HStack {
                    Text("\(count) settings").font(.callout.weight(.semibold))
                    Spacer()
                    TextField("Filter", text: $settingFilter).textFieldStyle(.roundedBorder).frame(width: 140)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                ForEach(filteredSettings) { setting in settingRow(setting) }
            }
            if !band.survey.config.isEmpty {
                Divider()
                Text("Config (\(band.survey.config.count) fields)").font(.callout.weight(.semibold))
                ForEach(band.survey.config, id: \.field) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("\(entry.field)").font(.caption.monospaced().weight(.bold)).frame(width: 30, alignment: .leading)
                            Text(configName(entry.field)).font(.caption.weight(.semibold))
                            Spacer()
                        }
                        Text(entry.value).font(.caption2.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
            }
        }
    }

    private var filteredSettings: [BandSetting] {
        let query = settingFilter.lowercased()
        return band.survey.settings.filter { setting in
            query.isEmpty || (setting.name ?? "").lowercased().contains(query) || "\(setting.id)" == query
        }
    }

    private func settingRow(_ setting: BandSetting) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("\(setting.id)").font(.caption.monospaced().weight(.bold)).frame(width: 30, alignment: .leading)
                Text(setting.name ?? "—").font(.caption.weight(.semibold)).foregroundStyle(setting.name == nil ? .secondary : .primary)
                if setting.dangerous {
                    Text("never written").font(.caption2.bold()).padding(.horizontal, 5).background(Theme.danger.opacity(0.3), in: Capsule())
                }
                Spacer()
                if let value = setting.value {
                    Text(value).font(.caption.monospaced().weight(.semibold)).foregroundStyle(Theme.mint)
                }
                if let kind = setting.valueKind { Text(kind).font(.caption2).foregroundStyle(.secondary) }
            }
            if !setting.details.isEmpty {
                Text(setting.details).font(.caption2.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if let problem = setting.problem, setting.name == nil || setting.value == nil {
                Text(problem).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func configName(_ field: UInt32) -> String {
        switch field {
        case 6: "device state (1 standby, 2 active, 4 handwriting)"
        case 10: "left-handed"
        case 42: "EMG config (rate, channels, bits, batch)"
        default: ""
        }
    }

    // MARK: experimental streams

    private static let knownStreams: [(field: UInt32, name: String, detail: String)] = [
        (4, "Model output", "The on-device model's raw scores (RawInferenceSample). Normal mode: wake/active pipelines"),
        (22, "Model stream 22", "Unnamed; Meta AI turns it on with 4 for the handwriting capture"),
        (23, "Model stream 23", "Unnamed; Meta AI turns it on with 4 for the handwriting capture"),
        (29, "Band orientation result", "Seen enabled by Meta AI; payload not yet decoded"),
        (43, "Inference text", "Text from the band; declined unless data collection is on"),
    ]

    private var streams: some View {
        Card(title: "Experimental streams", systemImage: "antenna.radiowaves.left.and.right") {
            Text("Ask the band for extra data streams and see what comes back below. Streams aren't saved on the band; leaving this screen or disconnecting turns them off.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(Self.knownStreams, id: \.field) { stream in
                Toggle(isOn: Binding(get: { band.probeRequested.contains(stream.field) }, set: { on in
                    var fields = band.probeRequested
                    if on { fields.insert(stream.field) } else { fields.remove(stream.field) }
                    band.setProbeStreams(fields)
                })) {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text("\(stream.field)").font(.caption.monospaced().weight(.bold))
                            Text(stream.name).font(.callout.weight(.semibold))
                            if let reported = band.probeReported[stream.field] {
                                Text(reported == 1 ? "on" : "off").font(.caption2.bold())
                                    .foregroundStyle(reported == 1 ? Theme.mint : .secondary)
                            }
                        }
                        Text(stream.detail).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .disabled(!connected || band.handwriting.active)
            }
            HStack {
                TextField("Other flag (1–64)", text: $customField).keyboardType(.numberPad).textFieldStyle(.roundedBorder)
                Button("Toggle") {
                    guard let field = UInt32(customField), BandSession.probeable(field) else {
                        customField = ""
                        return
                    }
                    var fields = band.probeRequested
                    if fields.contains(field) { fields.remove(field) } else { fields.insert(field) }
                    band.setProbeStreams(fields)
                }
                .buttonStyle(.bordered)
                .disabled(!connected || band.handwriting.active)
            }
            let custom = band.probeRequested.filter { field in !Self.knownStreams.contains { $0.field == field } }
            if !custom.isEmpty {
                Text("Also on: \(custom.sorted().map(String.init).joined(separator: ", "))").font(.caption.monospaced())
            }
            if let error = band.probeError { Text(error).font(.caption).foregroundStyle(Theme.warn) }
            Text("2, 3, 6 and 8 are off limits: the app needs them (raw EMG, gestures, gyro, orientation).").font(.caption2).foregroundStyle(.secondary)
            if !outputs.isEmpty {
                Divider()
                Text("Model outputs").font(.callout.weight(.semibold))
                ForEach(outputs.keys.sorted(), id: \.self) { pipeline in
                    if let sample = outputs[pipeline] { outputView(sample, count: outputCounts[pipeline] ?? 0) }
                }
            }
        }
    }

    private func outputView(_ sample: InferenceSample, count: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Pipeline \(sample.pipeline)").font(.caption.weight(.bold))
                Text(pipelineName(sample.pipeline)).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("\(sample.values.count) values · \(count) frames").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
            let shown = Array(sample.values.prefix(100))
            let low = shown.min() ?? 0, high = shown.max() ?? 1
            Canvas { context, size in
                let width = size.width / CGFloat(max(shown.count, 1))
                for (index, value) in shown.enumerated() {
                    let fraction = high > low ? CGFloat((value - low) / (high - low)) : 0.5
                    let rect = CGRect(x: CGFloat(index) * width, y: size.height * (1 - fraction), width: max(1, width - 1), height: size.height * fraction)
                    context.fill(Path(rect), with: .color(Theme.accent))
                }
            }
            .frame(height: 44)
            .background(.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
            if shown.count <= 12 {
                Text(shown.map { String(format: "%.2f", $0) }.joined(separator: "  ")).font(.caption2.monospaced()).foregroundStyle(.secondary)
            } else if sample.isTextDistribution, let best = Handwriting.top(sample.values, count: 1).first {
                Text("Top: \(best.index == Handwriting.blank ? "blank" : Handwriting.symbol(best.index)) \(String(format: "%.0f%%", best.probability * 100))")
                    .font(.caption2.monospaced()).foregroundStyle(.secondary)
            }
        }
    }

    private func pipelineName(_ pipeline: UInt64) -> String {
        switch pipeline {
        case 1: "wake"
        case 2: "active"
        case 3: "text (handwriting)"
        case 10: "cascade CC classifier"
        case 13: "cascade PC classifier"
        default: ""
        }
    }

    // MARK: messages

    private static let kindNames: [String: String] = [
        "0x02000001": "encryption request", "0x02000002": "encryption enabled",
        "0x02000314": "RPC request", "0x02000315": "RPC response", "0x02000316": "firmware log",
        "0x0200020a": "raw EMG", "0x0200020c": "model output", "0x0200020d": "gesture",
        "0x0200020f": "gyroscope", "0x02000212": "orientation",
        "0x02001000": "link setup / trust", "0x02001001": "band trust proof",
        "0x02003001": "identity", "0x03001000": "trust ack", "0x0300c001": "service rejected",
    ]

    private var messages: some View {
        Card(title: "Every message type the band sent", systemImage: "envelope.open") {
            let rows = band.diagnostics.messageCounts.sorted { $0.value > $1.value }
            if rows.isEmpty { Text("Nothing yet.").foregroundStyle(.secondary).font(.callout) }
            ForEach(rows, id: \.key) { kind, count in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(kind).font(.caption.monospaced())
                        Text(Self.kindNames[kind] ?? "undecoded").font(.caption.weight(.semibold))
                            .foregroundStyle(Self.kindNames[kind] == nil ? Theme.warn : .primary)
                        Spacer()
                        Text("\(count)").font(.caption.monospacedDigit())
                    }
                    if let shape = band.diagnostics.unknownShapes[kind] {
                        Text(shape).font(.caption2.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
            }
            Text("Undecoded kinds show their field layout (numbers and sizes, never the bytes).").font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var firmwareLog: some View {
        Card(title: "Band firmware log", systemImage: "text.alignleft") {
            ForEach(Array(band.firmwareLog.suffix(40).enumerated()), id: \.offset) { _, line in
                Text("\(line.date.formatted(date: .omitted, time: .standard))  \(line.text)").font(.caption2.monospaced())
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label).font(.callout).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.callout.monospaced()).multilineTextAlignment(.trailing).textSelection(.enabled)
        }
    }
}
