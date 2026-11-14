import BandKit
import BandLogging
import BandProtocol
import SwiftUI

/// Experimental raw sEMG viewer. The request flow (config read on 0x8007 → stream status → update
/// with flag 2) and the 2048 Hz × 8 ch × u16 layout come from band-core/kinesis; ADC scaling
/// and electrode order are unknown, so values are shown as raw counts with each channel's mean removed.
struct EMGView: View {
    @Environment(BandClient.self) private var band
    @State private var model = EMGModel()

    private var emptyReason: String { EMGModel.emptyReason(band: band, requested: band.wantsEmg, batches: model.batches) }

    var body: some View {
        List {
            Section {
                Toggle("Stream raw EMG", isOn: Binding(get: { band.emgStreaming || band.wantsEmg }, set: { band.setRawEmg($0) }))
                .disabled(band.phase != .streaming)
                if let config = band.emgConfig {
                    InfoRow(label: "Band config", value: "\(config.channels) ch @ \(config.sampleRate) Hz, \(config.adcBits)-bit, \(config.samplesPerBatch)/batch, enc \(config.encoding)")
                    if !config.isSupported { Text("This layout isn't the observed one, so it isn't decoded. No data is invented.").foregroundStyle(Theme.warn) }
                }
                InfoRow(label: "Batches", value: "\(model.batches)")
                InfoRow(label: "Received rate", value: model.rate > 0 ? String(format: "%.0f samples/s per channel", model.rate) : "—")
                InfoRow(label: "Sequence gaps", value: "\(model.gaps)")
                if let error = band.emgError { Text(error).foregroundStyle(Theme.danger).font(.callout) }
            } footer: {
                Text("If the band refuses raw EMG, or sends a layout that isn't the observed one, this screen says so instead of making up data. Raw EMG roughly doubles Bluetooth traffic.")
            }
            Section("Waveforms (8 channels, mean removed)") {
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
                    EMGTrace(model: model, tick: timeline.date, emptyReason: emptyReason).frame(height: 360)
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
            }
            Section("Recording") {
                if model.recording {
                    Label("Recording… \(model.recordedRows) samples", systemImage: "record.circle").foregroundStyle(Theme.danger)
                    Button("Stop recording") { model.stopRecording() }
                } else {
                    Button("Start CSV recording") { model.startRecording() }.disabled(!band.emgStreaming)
                }
                if let url = model.lastRecording {
                    ShareLink(item: url) { Label("Share \(url.lastPathComponent)", systemImage: "square.and.arrow.up") }
                }
            }
        }
        .navigationTitle("Raw EMG")
        .task {
            for await event in band.events.subscribe(buffer: 8192) {
                if case .emg(let batch, let at) = event { model.ingest(batch, at: at) }
            }
        }
        .onDisappear {
            if model.recording { model.stopRecording() }
        }
    }
}

@MainActor
@Observable
final class EMGModel {
    static let window = 2048
    private(set) var batches = 0
    private(set) var gaps = 0
    private(set) var rate = 0.0
    private(set) var recording = false
    private(set) var recordedRows = 0
    private(set) var lastRecording: URL?
    @ObservationIgnored var channels: [[Float]] = Array(repeating: [], count: 8)
    @ObservationIgnored private var lastSequence: UInt64?
    @ObservationIgnored private var rateStart = 0.0
    @ObservationIgnored private var rateSamples = 0
    @ObservationIgnored private var file: FileHandle?
    @ObservationIgnored private var fileURL: URL?
    @ObservationIgnored private var buffer = ""

    /// Why no waveform is showing, in plain words.
    static func emptyReason(band: BandClient, requested: Bool, batches: Int) -> String {
        if band.phase != .streaming { return "Connect the band first" }
        if let error = band.emgError { return error }
        if let config = band.emgConfig, !config.isSupported { return "Band uses an EMG layout this viewer doesn't decode" }
        if !requested && !band.emgStreaming { return "Tap Start EMG" }
        if band.emgConfig == nil { return "Asking the band for its EMG configuration…" }
        if !band.emgStreaming { return "Waiting for the band to confirm EMG…" }
        return batches == 0 ? "EMG confirmed, waiting for the first samples…" : "Waiting for EMG samples…"
    }

    func ingest(_ batch: EmgBatch, at time: Double) {
        if batches == 0 { logNotice(.emg, "Viewer: first EMG batch drawn (seq \(batch.sequence), \(batch.values.count) values)") }
        batches += 1
        if let last = lastSequence, batch.sequence != last &+ 1 { gaps += 1 }
        lastSequence = batch.sequence
        for sample in 0..<EmgBatch.samples {
            for channel in 0..<EmgBatch.channels { channels[channel].append(Float(batch.value(sample: sample, channel: channel))) }
        }
        for channel in 0..<8 where channels[channel].count > Self.window { channels[channel].removeFirst(channels[channel].count - Self.window) }
        if rateStart == 0 { rateStart = time }
        rateSamples += EmgBatch.samples
        if time - rateStart >= 1 {
            rate = Double(rateSamples) / (time - rateStart)
            rateStart = time
            rateSamples = 0
        }
        if recording {
            for sample in 0..<EmgBatch.samples {
                let values = (0..<8).map { String(batch.value(sample: sample, channel: $0)) }.joined(separator: ",")
                buffer += "\(String(format: "%.6f", time)),\(batch.sequence),\(batch.timestampMicros),\(sample),\(values)\n"
            }
            recordedRows += EmgBatch.samples
            if buffer.utf8.count > 64_000 { flush() }
        }
    }

    func startRecording() {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("emg-\(stamp).csv")
        FileManager.default.createFile(atPath: url.path, contents: Data("host_uptime_s,sequence,band_timestamp_us,sample_in_batch,ch0,ch1,ch2,ch3,ch4,ch5,ch6,ch7\n".utf8))
        file = try? FileHandle(forWritingTo: url)
        file?.seekToEndOfFile()
        fileURL = url
        recordedRows = 0
        recording = file != nil
        logNotice(.emg, "EMG recording started: \(url.lastPathComponent)")
    }

    func stopRecording() {
        flush()
        try? file?.close()
        file = nil
        recording = false
        lastRecording = fileURL
        logNotice(.emg, "EMG recording stopped: \(recordedRows) samples")
    }

    private func flush() {
        guard !buffer.isEmpty else { return }
        file?.write(Data(buffer.utf8))
        buffer = ""
    }
}

struct EMGTrace: View {
    let model: EMGModel
    /// Changes every frame. `model.channels` isn't observed (it updates ~2,000×/s), so without a
    /// changing input SwiftUI considers the view unchanged and never redraws the Canvas.
    let tick: Date
    /// Why the chart is empty, shown instead of a blank box.
    var emptyReason: String = "Waiting for EMG samples…"
    static let colors: [Color] = [.red, .orange, .yellow, .green, .mint, .cyan, .blue, .purple]

    var body: some View {
        Canvas { context, size in
            let lane = size.height / 8
            if model.channels.allSatisfy(\.isEmpty) {
                context.draw(Text(emptyReason).font(.callout).foregroundStyle(.secondary),
                             at: CGPoint(x: size.width / 2, y: size.height / 2))
                return
            }
            for channel in 0..<8 {
                let values = model.channels[channel]
                let top = CGFloat(channel) * lane
                context.stroke(Path { $0.move(to: CGPoint(x: 0, y: top + lane / 2)); $0.addLine(to: CGPoint(x: size.width, y: top + lane / 2)) },
                               with: .color(.white.opacity(0.06)))
                context.draw(Text("ch\(channel)").font(.system(size: 9)).foregroundStyle(.secondary), at: CGPoint(x: 14, y: top + 8))
                guard values.count > 2 else { continue }
                let mean = values.reduce(0, +) / Float(values.count)
                let spread = max(50, values.map { abs($0 - mean) }.max() ?? 50)
                let step = max(1, values.count / Int(size.width))
                var path = Path()
                var index = 0
                var first = true
                while index < values.count {
                    let x = size.width * CGFloat(index) / CGFloat(EMGModel.window)
                    let y = top + lane / 2 - CGFloat((values[index] - mean) / spread) * lane * 0.45
                    if first { path.move(to: CGPoint(x: x, y: y)); first = false } else { path.addLine(to: CGPoint(x: x, y: y)) }
                    index += step
                }
                context.stroke(path, with: .color(Self.colors[channel]), lineWidth: 1)
            }
        }
        .background(.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
    }
}
