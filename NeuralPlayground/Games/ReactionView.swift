import BandKit
import BandLogging
import BandProtocol
import SwiftUI

/// Shows a target after a random delay and measures the time until a finger gesture arrives.
/// Latency uses the host time the band message was decoded, so it includes your reaction, the
/// band's on-device recognition, and Bluetooth delivery — not the app's UI handling.
struct ReactionView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case anyTap = "Any tap"
        case prompted = "Prompted finger"
        var id: Self { self }
    }

    enum Phase: Equatable { case idle, waiting, target(Finger?), result(String) }

    struct Trial: Identifiable {
        let id = UUID()
        let milliseconds: Double
        let source: EventSource
        let gesture: RecognizedGesture
    }

    @Environment(BandClient.self) private var band
    @Environment(AppModel.self) private var model
    @State private var phase = Phase.idle
    @State private var mode = Mode.anyTap
    @State private var input = GameInput.band
    @State private var shownAt = 0.0
    @State private var trials: [Trial] = []
    @State private var waitTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 14) {
            Picker("Input", selection: $input) { ForEach(GameInput.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
            Picker("Mode", selection: $mode) { ForEach(Mode.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
            arena
            stats
            List(trials.reversed()) { trial in
                HStack {
                    Text(String(format: "%.0f ms", trial.milliseconds)).font(.headline.monospacedDigit())
                    Text(trial.gesture.title).foregroundStyle(.secondary)
                    Spacer()
                    SourceBadge(source: trial.source)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
        .padding()
        .screenBackground()
        .navigationTitle("Reaction time")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { Button("Reset") { trials.removeAll(); cancel() } }
        }
        .task {
            for await event in band.events.subscribe() {
                if case .gesture(let gesture) = event { handle(gesture) }
            }
        }
        .onDisappear { cancel() }
    }

    private var arena: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 28).fill(background)
            switch phase {
            case .idle:
                VStack(spacing: 10) {
                    Image(systemName: "timer").font(.system(size: 44))
                    Text("Tap Start, then gesture as soon as the target appears.").multilineTextAlignment(.center)
                    Button("Start") { arm() }.buttonStyle(.borderedProminent).controlSize(.large)
                }
                .padding()
            case .waiting:
                VStack(spacing: 8) {
                    Text("Wait…").font(.largeTitle.bold())
                    Text("Don't gesture yet").foregroundStyle(.secondary)
                }
            case .target(let finger):
                VStack(spacing: 10) {
                    Circle().fill(.white).frame(width: 120, height: 120)
                        .overlay(Image(systemName: "hand.tap.fill").font(.system(size: 48)).foregroundStyle(.black))
                        .transition(.scale.combined(with: .opacity))
                    Text(finger.map { "\($0.rawValue.uppercased()) TAP!" } ?? "TAP!").font(.largeTitle.weight(.heavy))
                }
            case .result(let text):
                VStack(spacing: 10) {
                    Text(text).font(.title.bold()).multilineTextAlignment(.center)
                    Button("Next") { arm() }.buttonStyle(.borderedProminent)
                }
            }
        }
        .frame(height: 300)
        .contentShape(Rectangle())
        .onTapGesture {
            guard input == .touch else { return }
            switch phase {
            case .waiting, .target:
                handle(GestureEvent(gesture: .tap(.index, .tap), source: .touch))
            default: break
            }
        }
        .animation(.spring(duration: 0.25), value: phase)
    }

    private var background: Color {
        switch phase {
        case .waiting: Theme.danger.opacity(0.35)
        case .target: Theme.mint.opacity(0.7)
        default: Theme.card
        }
    }

    private var stats: some View {
        let values = trials.map(\.milliseconds).sorted()
        let average = values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
        let median = values.isEmpty ? nil : values[values.count / 2]
        return HStack {
            stat("Best", values.first)
            stat("Median", median)
            stat("Average", average)
            stat("Trials", values.isEmpty ? nil : Double(values.count), unit: "")
        }
    }

    private func stat(_ label: String, _ value: Double?, unit: String = " ms") -> some View {
        VStack {
            Text(value.map { String(format: "%.0f", $0) + unit } ?? "—").font(.headline.monospacedDigit())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func arm() {
        cancel()
        phase = .waiting
        let delay = Double.random(in: 1.5...4.0)
        waitTask = Task {
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            shownAt = ProcessInfo.processInfo.systemUptime
            phase = .target(mode == .prompted ? Finger.allCases.randomElement() : nil)
        }
    }

    private func cancel() {
        waitTask?.cancel()
        waitTask = nil
        if case .result = phase {} else if phase != .idle { phase = .idle }
    }

    private func handle(_ event: GestureEvent) {
        let accepted: Bool = switch event.source {
        case .band: input == .band
        case .simulated: input == .band && model.simulationEnabled
        case .touch: input == .touch
        }
        guard accepted, case .tap(let finger, let kind) = event.gesture, kind == .tap else { return }
        switch phase {
        case .waiting:
            waitTask?.cancel()
            phase = .result("Too soon! 🚫\nWait for the green target.")
            logInfo(.games, "Reaction: false start")
        case .target(let expected):
            if let expected, expected != finger {
                phase = .result("Wrong finger: expected \(expected.rawValue).")
                return
            }
            let milliseconds = max(0, (event.uptime - shownAt) * 1000)
            trials.append(Trial(milliseconds: milliseconds, source: event.source, gesture: event.gesture))
            phase = .result(String(format: "%.0f ms", milliseconds))
            logInfo(.games, "Reaction: \(Int(milliseconds)) ms via \(event.source.rawValue) (\(event.gesture.title))")
        default:
            break
        }
    }
}
