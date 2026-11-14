import BandKit
import BandLogging
import BandProtocol
import SwiftUI

/// The band's own handwriting model, live: decoded text plus the raw per-frame scores it sends.
/// Starting it changes two band settings (found by name, snapshotted, read back); stopping, leaving
/// this screen or disconnecting puts them back, and an interrupted capture is restored on the next connect.
struct HandwritingView: View {
    @Environment(BandClient.self) private var band
    @State private var decoder = HandwritingDecoder()
    @State private var latest: InferenceSample?
    @State private var history: [(best: Int, probability: Double)] = []
    @State private var frames = 0
    @State private var rate = 0.0
    @State private var rateStart = Date()
    @State private var rateFrames = 0

    private var status: ModelCaptureStatus { band.handwriting }
    private var running: Bool { status.active }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                statusCard
                textCard
                frameCard
                tokensCard
                Text("Write with your index finger on any surface (your leg, a table) or in the air. Middle tap clears. The band runs Meta's handwriting model on the device; the app decodes its 100 scores per frame the way Meta AI does (band-core).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding()
        }
        .screenBackground()
        .navigationTitle("Handwriting")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { ConnectionPill() } }
        .onDisappear { band.stopHandwriting() }
        .task {
            for await event in band.events.subscribe(buffer: 4096) {
                switch event {
                case .inference(let sample) where sample.isTextDistribution:
                    latest = sample
                    decoder.push(sample.values)
                    frames += 1
                    let nonBlank = sample.values.enumerated().filter { $0.offset != Handwriting.blank }.max { $0.element < $1.element }
                    history.append((nonBlank?.offset ?? Handwriting.blank, exp(Double(nonBlank?.element ?? -50))))
                    if history.count > 90 { history.removeFirst(history.count - 90) }
                    rateFrames += 1
                    if Date().timeIntervalSince(rateStart) >= 1 {
                        rate = Double(rateFrames) / Date().timeIntervalSince(rateStart)
                        rateFrames = 0
                        rateStart = Date()
                    }
                case .gesture(let gesture) where gesture.gesture == .tap(.middle, .tap) && running:
                    decoder.clear()
                default: break
                }
            }
        }
    }

    private var statusCard: some View {
        Card(title: "Band handwriting model", systemImage: "pencil.and.scribble") {
            HStack {
                Circle().fill(color).frame(width: 10, height: 10)
                Text(status.phase == .idle ? "Off" : status.message).font(.callout.weight(.semibold))
                Spacer()
            }
            if let problem = status.problem { Text(problem).font(.caption).foregroundStyle(Theme.danger) }
            if status.phase == .finished {
                Label(status.restorationVerified ? "Band settings restored and verified" : "Restoration not verified: reconnect and it will retry",
                      systemImage: status.restorationVerified ? "checkmark.seal.fill" : "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(status.restorationVerified ? Theme.mint : Theme.warn)
            }
            HStack {
                Button {
                    if running { band.stopHandwriting() } else { decoder.clear(); history = []; frames = 0; band.startHandwriting() }
                } label: {
                    Label(running ? "Stop and restore" : "Start handwriting", systemImage: running ? "stop.circle" : "play.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(band.phase != .streaming || status.phase == .restoring)
            }
            Text("Your band stays on its current firmware. If this firmware doesn't have the handwriting model, the app says so and changes nothing.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var color: Color {
        switch status.phase {
        case .ready: Theme.mint
        case .preparing, .restoring: Theme.warn
        case .finished: status.problem == nil ? .gray : Theme.danger
        case .idle: .gray
        }
    }

    private var textCard: some View {
        Card(title: "Decoded text", systemImage: "character.cursor.ibeam") {
            Text(decoder.text.isEmpty ? (status.phase == .ready ? "Start writing…" : "—") : decoder.text)
                .font(.system(size: 34, weight: .semibold, design: .rounded))
                .frame(maxWidth: .infinity, minHeight: 70, alignment: .leading)
                .textSelection(.enabled)
                .contentTransition(.numericText())
                .animation(.snappy, value: decoder.text)
            HStack {
                Button("Clear") { decoder.clear() }.font(.caption)
                Spacer()
                Button("Copy") { SecureClipboard.copy(decoder.text) }.font(.caption).disabled(decoder.text.isEmpty)
            }
        }
    }

    private var frameCard: some View {
        Card(title: "What the band sends", systemImage: "waveform") {
            HStack {
                stat("Frames", "\(frames)")
                stat("Rate", rate > 0 ? String(format: "%.1f/s", rate) : "—")
                stat("Pipeline", latest.map { "\($0.pipeline)" } ?? "—")
                stat("Model latency", latest?.latencyMicros.map { "\($0 / 1000) ms" } ?? "—")
            }
            if let latest {
                ForEach(Handwriting.top(latest.values, count: 5), id: \.index) { entry in
                    HStack {
                        Text(entry.index == Handwriting.blank ? "blank" : entry.index == Handwriting.pause ? "pause" : Handwriting.symbol(entry.index))
                            .font(.callout.monospaced().weight(.bold)).frame(width: 56, alignment: .leading)
                        GeometryReader { geometry in
                            RoundedRectangle(cornerRadius: 3)
                                .fill(entry.index == Handwriting.blank ? Color.gray : Theme.accent)
                                .frame(width: max(2, geometry.size.width * entry.probability))
                        }
                        .frame(height: 12)
                        Text(String(format: "%5.1f%%", entry.probability * 100)).font(.caption.monospacedDigit()).frame(width: 56, alignment: .trailing)
                    }
                }
            } else {
                Text("No frames yet.").foregroundStyle(.secondary).font(.callout)
            }
            Text("Recent frames: the bar is the most likely non-blank symbol's probability").font(.caption2).foregroundStyle(.secondary)
            Canvas { context, size in
                guard !history.isEmpty else { return }
                let width = size.width / 90
                for (i, entry) in history.enumerated() {
                    let height = size.height * CGFloat(entry.probability)
                    let rect = CGRect(x: CGFloat(i) * width, y: size.height - height, width: max(1, width - 1), height: height)
                    let color: Color = entry.probability > 0.5 ? Theme.mint : entry.probability > 0.2 ? Theme.warn : .gray
                    context.fill(Path(rect), with: .color(color))
                }
            }
            .frame(height: 60)
            .background(.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var tokensCard: some View {
        Card(title: "Symbols as they arrived", systemImage: "textformat.abc") {
            let tokens = Array(decoder.tokens.suffix(40))
            if tokens.isEmpty { Text("—").foregroundStyle(.secondary) }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 38))], spacing: 6) {
                ForEach(Array(tokens.enumerated()), id: \.offset) { _, token in
                    Text(token.index == Handwriting.pause ? "⏸" : Handwriting.symbol(token.index))
                        .font(.callout.monospaced().weight(.bold))
                        .frame(width: 34, height: 30)
                        .background((token.margin > 3 ? Theme.mint : token.margin > 1 ? Theme.warn : Color.gray).opacity(0.3),
                                    in: RoundedRectangle(cornerRadius: 6))
                }
            }
            Text("Color = how sure the band was (green sure, orange unsure)").font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.callout.monospacedDigit().weight(.semibold))
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}
