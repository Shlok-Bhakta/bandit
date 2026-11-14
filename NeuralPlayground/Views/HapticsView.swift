import BandKit
import BandLogging
import BandProtocol
import SwiftUI

/// Haptics lab: the band's vibrate RPC (duration + amplitude), its two verified feedback
/// patterns, and app-side patterns composed from sequential vibrations.
struct HapticsView: View {
    @Environment(BandClient.self) private var band
    @State private var duration = 120.0
    @State private var amplitude = 200.0
    @State private var results: [Entry] = []
    @State private var running: String?

    struct Entry: Identifiable {
        let id = UUID()
        let label: String
        let result: HapticsResult
        let date = Date()
    }

    struct Pattern {
        let name: String
        let steps: [(duration: UInt64, amplitude: UInt8, pause: UInt64)]
    }

    static let patterns: [Pattern] = [
        Pattern(name: "Double pulse", steps: [(60, 255, 90), (60, 255, 0)]),
        Pattern(name: "Heartbeat", steps: [(80, 220, 120), (140, 160, 600), (80, 220, 120), (140, 160, 0)]),
        Pattern(name: "Ramp up", steps: [(80, 60, 60), (80, 120, 60), (80, 180, 60), (120, 255, 0)]),
        Pattern(name: "Notification", steps: [(40, 140, 80), (40, 140, 80), (220, 255, 0)]),
        Pattern(name: "SOS", steps: [(70, 255, 90), (70, 255, 90), (70, 255, 220), (240, 255, 90), (240, 255, 90), (240, 255, 220),
                                     (70, 255, 90), (70, 255, 90), (70, 255, 0)]),
    ]

    var body: some View {
        List {
            if band.phase != .streaming {
                Section { Label("Connect your band to test haptics.", systemImage: "exclamationmark.circle").foregroundStyle(Theme.warn) }
            }
            Section {
                VStack(alignment: .leading) {
                    Text("Duration: \(Int(duration)) ms")
                    Slider(value: $duration, in: 10...Double(HapticsCommand.maxDurationMs), step: 10)
                }
                VStack(alignment: .leading) {
                    Text("Amplitude: \(Int(amplitude)) / 255")
                    Slider(value: $amplitude, in: 0...255, step: 1)
                }
                Button { Task { await send(.vibrate(durationMs: UInt64(duration), amplitude: UInt8(amplitude)), label: "Vibrate \(Int(duration)) ms @ \(Int(amplitude))") } } label: {
                    Label("Vibrate", systemImage: "waveform").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).disabled(running != nil)
            } header: {
                Text("Custom vibration")
            } footer: {
                Text("Encoded as band-core does: HapticsReq.Vibrate { duration_ms, amplitude }. The band decides how amplitude maps to strength, and very short or very low values may not be felt.")
            }
            Section {
                ForEach(HapticsCommand.verifiedPatterns, id: \.self) { id in
                    Button("Band feedback pattern \(id)") { Task { await send(.perform(patternID: id), label: "Band pattern \(id)") } }
                        .disabled(running != nil)
                }
            } header: {
                Text("Built-in band patterns (verified)")
            } footer: {
                Text("band-core verifies only patterns 1 and 2 (gesture feedback). Other IDs are refused on purpose.")
            }
            Section {
                ForEach(Self.patterns, id: \.name) { pattern in
                    Button {
                        Task { await play(pattern) }
                    } label: {
                        HStack {
                            Text(pattern.name)
                            Spacer()
                            if running == pattern.name { ProgressView() }
                        }
                    }
                    .disabled(running != nil)
                }
            } header: {
                Text("Composed patterns")
            } footer: {
                Text("Played as a sequence of vibrate commands. Each one waits for the band's acknowledgement, so the timing includes the Bluetooth round trip.")
            }
            Section("Results") {
                if results.isEmpty { Text("No haptics sent yet").foregroundStyle(.secondary) }
                ForEach(results) { entry in
                    HStack {
                        Image(systemName: entry.result.rpcSuccess ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(entry.result.rpcSuccess ? Theme.mint : Theme.danger)
                        VStack(alignment: .leading) {
                            Text(entry.label)
                            Text(detail(entry.result)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(entry.date.formatted(.dateTime.hour().minute().second())).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Haptics lab")
    }

    private func detail(_ result: HapticsResult) -> String {
        if let error = result.error, !result.rpcSuccess { return error }
        var parts = ["acknowledged"]
        if let ok = result.hapticsSuccess { parts.append(ok ? "haptics ok" : "haptics reported an error") }
        if let trip = result.roundTrip { parts.append("\(Int(trip * 1000)) ms round trip") }
        return parts.joined(separator: " · ")
    }

    @discardableResult
    private func send(_ command: HapticsCommand, label: String) async -> HapticsResult {
        let result = await band.haptic(command)
        results.insert(Entry(label: label, result: result), at: 0)
        if results.count > 50 { results.removeLast() }
        return result
    }

    private func play(_ pattern: Pattern) async {
        running = pattern.name
        defer { running = nil }
        logInfo(.haptics, "Playing composed pattern \(pattern.name) (\(pattern.steps.count) steps)")
        for (index, step) in pattern.steps.enumerated() {
            let result = await send(.vibrate(durationMs: step.duration, amplitude: step.amplitude), label: "\(pattern.name) \(index + 1)/\(pattern.steps.count)")
            guard result.delivered else { return }
            try? await Task.sleep(for: .milliseconds(Int(step.duration + step.pause)))
        }
    }
}
