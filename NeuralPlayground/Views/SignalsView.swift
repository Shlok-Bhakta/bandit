import BandKit
import BandLogging
import BandProtocol
import SwiftUI

/// Everything the band is sending, live: message rates by type, raw EMG, gyro and orientation.
struct SignalsView: View {
    @Environment(BandClient.self) private var band
    @Environment(AppModel.self) private var model
    @State private var emg = EMGModel()
    @State private var rates: [String: Double] = [:]
    @State private var previous: [String: Int] = [:]
    @State private var previousAt = Date()
    @State private var demo = false

    static let names: [String: String] = [
        "0x0200020d": "Gesture", "0x0200020f": "Gyro", "0x02000212": "Orientation (quaternion)",
        "0x0200020a": "Raw EMG", "0x0200020c": "Model inference", "0x02000315": "RPC response",
        "0x02000316": "Band log line", "0x02001000": "Link setup", "0x02001001": "Band trust proof",
        "0x0300c001": "Service rejected",
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if band.phase != .streaming {
                    Label("Connect your band to see live data.", systemImage: "antenna.radiowaves.left.and.right.slash")
                        .foregroundStyle(Theme.warn).frame(maxWidth: .infinity, alignment: .leading)
                }
                emgCard
                Card(title: "Messages from the band", systemImage: "tray.and.arrow.down") {
                    let rows = band.diagnostics.messageCounts.sorted { $0.value > $1.value }
                    if rows.isEmpty { Text("Nothing received yet").foregroundStyle(.secondary) }
                    ForEach(rows, id: \.key) { kind, count in
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(Self.names[kind] ?? "Unknown").font(.callout.weight(.semibold))
                                Text(kind).font(.caption2.monospaced()).foregroundStyle(.secondary)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 1) {
                                Text(String(format: "%.0f/s", rates[kind] ?? 0)).font(.callout.monospacedDigit())
                                Text("\(count) total").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                    }
                    InfoRow(label: "Bytes in / out", value: "\(band.diagnostics.bytesIn) / \(band.diagnostics.bytesOut)")
                    InfoRow(label: "Decode failures", value: "\(band.diagnostics.decodeFailures)")
                }
                Card(title: "Gyro (°/s)", systemImage: "gyroscope") {
                    GyroTrace(history: model.sensors.gyroHistory).frame(height: 120)
                    Text(String(format: "x %+7.1f   y %+7.1f   z %+7.1f", model.sensors.gyro.x, model.sensors.gyro.y, model.sensors.gyro.z))
                        .font(.caption.monospacedDigit())
                    InfoRow(label: "Rate", value: model.sensors.motionRate > 0 ? String(format: "%.0f Hz", model.sensors.motionRate) : "—")
                }
                Card(title: "Orientation", systemImage: "rotate.3d") {
                    if let q = model.sensors.orientation {
                        Text(String(format: "w %+.3f  x %+.3f  y %+.3f  z %+.3f", q.x, q.y, q.z, q.w)).font(.caption.monospacedDigit())
                    }
                    let e = model.sensors.euler
                    Text(String(format: "roll %+6.1f°  pitch %+6.1f°  yaw %+6.1f°", e.roll, e.pitch, e.yaw)).font(.callout.monospacedDigit())
                }
            }
            .padding()
        }
        .screenBackground()
        .navigationTitle("Live signals")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { ConnectionPill() } }
        .task {
            #if DEBUG
            // Rendering check only (`-NPDemoSignals YES`): synthetic waveforms, labeled DEMO DATA.
            if UserDefaults.standard.bool(forKey: "NPDemoSignals") {
                demo = true
                var sequence: UInt64 = 0
                while !Task.isCancelled {
                    sequence += 1
                    let t0 = Double(sequence) * 16 / 2048
                    let values: [UInt16] = (0..<16).flatMap { sample in (0..<8).map { channel in
                        let t = t0 + Double(sample) / 2048
                        let burst = sin(t * 2) > 0.3 ? 900.0 : 120.0
                        return UInt16(32768 + sin(t * Double(40 + channel * 13) * .pi) * burst + Double.random(in: -60...60))
                    } }
                    emg.ingest(EmgBatch(sequence: sequence, timestampMicros: sequence * 7812, values: values), at: ProcessInfo.processInfo.systemUptime)
                    try? await Task.sleep(for: .milliseconds(8))
                }
            }
            #endif
            for await event in band.events.subscribe(buffer: 8192) {
                if case .emg(let batch, let at) = event { emg.ingest(batch, at: at) }
            }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                let now = Date()
                let elapsed = max(0.1, now.timeIntervalSince(previousAt))
                let counts = band.diagnostics.messageCounts
                rates = counts.mapValues { _ in 0 }.merging(counts.map { ($0.key, Double($0.value - (previous[$0.key] ?? $0.value)) / elapsed) }) { $1 }
                previous = counts
                previousAt = now
            }
        }
        .onDisappear { if emg.recording { emg.stopRecording() } }
    }

    private var emgCard: some View {
        Card(title: "Muscle signals (raw sEMG)", systemImage: "waveform.path") {
            if demo { Text("DEMO DATA: synthetic rendering test, not from the band").badgeStyle(Theme.warn) }
            HStack {
                Button {
                    band.setRawEmg(!band.wantsEmg)
                } label: {
                    Label(band.emgStreaming ? "Stop EMG" : (band.wantsEmg ? "Starting…" : "Start EMG"), systemImage: band.emgStreaming ? "stop.circle" : "play.circle")
                }
                .buttonStyle(.borderedProminent).disabled(band.phase != .streaming)
                Spacer()
                if band.emgStreaming { Label("Live", systemImage: "dot.radiowaves.left.and.right").foregroundStyle(Theme.mint).font(.caption.bold()) }
            }
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
                EMGTrace(model: emg, tick: timeline.date,
                         emptyReason: EMGModel.emptyReason(band: band, requested: band.wantsEmg, batches: emg.batches))
                    .frame(height: 300)
            }
            HStack {
                Text("\(emg.batches) batches").font(.caption.monospacedDigit())
                Spacer()
                Text(emg.rate > 0 ? String(format: "%.0f samples/s/ch", emg.rate) : "—").font(.caption.monospacedDigit())
                Spacer()
                Text("\(emg.gaps) gaps").font(.caption.monospacedDigit())
            }
            .foregroundStyle(.secondary)
            if let config = band.emgConfig {
                Text("Band config: \(config.channels) ch @ \(config.sampleRate) Hz, \(config.adcBits)-bit, encoding \(config.encoding)\(config.isSupported ? "" : ". Not the observed layout, so it isn't decoded.")")
                    .font(.caption).foregroundStyle(config.isSupported ? Color.secondary : Theme.warn)
            }
            if let error = band.emgError { Text(error).font(.caption).foregroundStyle(Theme.danger) }
            Text("Raw counts from the 8 electrodes, mean removed per channel. Tense your forearm or move your fingers to see them react. Voltage scaling and electrode order aren't documented.")
                .font(.caption2).foregroundStyle(.secondary)
            NavigationLink { EMGView() } label: { Label("Record EMG to CSV", systemImage: "record.circle").font(.footnote) }
        }
    }
}
