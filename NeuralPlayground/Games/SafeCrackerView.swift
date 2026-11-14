import BandKit
import BandProtocol
import SwiftUI

/// Safe Cracker: twist your wrist to turn a 40-number dial. The band clicks on every notch and gives a
/// heavier thunk on the right number; index tap locks it in. Middle hold = new combination.
/// The whole dial fits in a comfortable twist (≈120° by default), and holding an index pinch lets go of
/// the dial so you can re-grip, like turning a key.
struct SafeCrackerView: View {
    @Environment(BandClient.self) private var band
    @Environment(AppModel.self) private var model
    @State private var combination: [Int] = SafeCrackerView.newCombination()
    @State private var step = 0
    @State private var dialNumber = 0
    @State private var opened = false
    @State private var shake = 0
    @State private var showHint = false
    /// Degrees of wrist twist for the whole 40-number dial.
    @State private var fullTurn = 120.0
    /// The dial's own angle in twist-degrees; only moves while not re-gripping.
    @State private var dialPosition = 0.0
    @State private var lastTwist: Double?
    private var degreesPerNumber: Double { fullTurn / Double(Self.numbers) }
    @State private var startedAt = Date()
    @State private var openedIn: TimeInterval?

    private var engine: MotionEngine { model.motion }
    static let numbers = 40

    static func newCombination() -> [Int] { (0..<3).map { _ in Int.random(in: 0..<numbers) } }

    var body: some View {
        VStack(spacing: 18) {
            HStack(spacing: 14) {
                ForEach(0..<3, id: \.self) { index in
                    Text(index < step || opened ? String(format: "%02d", combination[index]) : (showHint && index == step ? String(format: "%02d", combination[index]) : "••"))
                        .font(.system(size: 26, weight: .bold, design: .monospaced))
                        .frame(width: 70, height: 50)
                        .background((index < step || opened ? Theme.mint : Theme.card).opacity(index < step || opened ? 0.35 : 1), in: RoundedRectangle(cornerRadius: 12))
                }
            }
            ZStack {
                dial
                if opened {
                    VStack(spacing: 8) {
                        Image(systemName: "lock.open.fill").font(.system(size: 54)).foregroundStyle(Theme.mint)
                        Text("Cracked!").font(.title.bold())
                        if let openedIn { Text(String(format: "%.1f s", openedIn)).font(.headline.monospacedDigit()) }
                        Text("Hold your middle finger for a new safe").font(.footnote).foregroundStyle(.secondary)
                    }
                    .padding(24).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
                }
            }
            .modifier(Shake(amount: CGFloat(shake)))
            .animation(.default, value: shake)
            Text(opened ? "" : "Twist your wrist to turn the dial. Feel the clicks; the right number lands with a heavier thunk. Index tap locks it in. Running out of twist? Hold an index pinch to let go, turn back, and release to grab the dial again.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            HStack {
                Button("Center wrist") { engine.calibrateTwist() }.buttonStyle(.bordered)
                Toggle("Show next number", isOn: $showHint).font(.caption)
            }
            HStack {
                Text("Full dial = \(Int(fullTurn))° of twist").font(.caption)
                Slider(value: $fullTurn, in: 60...240, step: 10)
            }
            if engine.indexHeld && !opened {
                Label("Re-gripping: the dial is free", systemImage: "hand.pinch.fill").font(.caption).foregroundStyle(Theme.warn)
            }
            Spacer()
        }
        .padding()
        .screenBackground()
        .navigationTitle("Safe Cracker")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { ConnectionPill() } }
        .onAppear { engine.calibrateTwist(); startedAt = Date(); lastTwist = nil }
        .onChange(of: engine.twist) { _, twist in
            defer { lastTwist = twist }
            guard let lastTwist else { return }
            // Holding an index pinch lets go of the dial (re-grip); otherwise the dial follows the wrist.
            if !engine.indexHeld { dialPosition += twist - lastTwist }
            let raw = Int((dialPosition / degreesPerNumber).rounded())
            let number = ((raw % Self.numbers) + Self.numbers) % Self.numbers
            guard number != dialNumber else { return }
            dialNumber = number
            guard !opened else { return }
            if number == combination[step] {
                engine.tick(durationMs: 55, amplitude: 255, spacing: 0)  // the thunk
            } else {
                engine.tick(durationMs: 12, amplitude: 110, spacing: 0.035)  // a notch click
            }
        }
        .task {
            for await event in band.events.subscribe() {
                guard case .gesture(let gesture) = event, gesture.source == .band || model.simulationEnabled else { continue }
                switch gesture.gesture {
                case .tap(.index, .tap): lockIn()
                case .tap(.middle, .hold): reset()
                default: break
                }
            }
        }
    }

    private var dial: some View {
        ZStack {
            Circle().fill(LinearGradient(colors: [Color(white: 0.25), Color(white: 0.08)], startPoint: .top, endPoint: .bottom))
                .overlay(Circle().stroke(Color(white: 0.45), lineWidth: 4))
            ForEach(0..<Self.numbers, id: \.self) { n in
                VStack {
                    Rectangle().fill(.white.opacity(n % 5 == 0 ? 0.9 : 0.4)).frame(width: n % 5 == 0 ? 3 : 1.5, height: n % 5 == 0 ? 16 : 9)
                    if n % 5 == 0 { Text("\(n)").font(.system(size: 13, weight: .bold, design: .monospaced)).foregroundStyle(.white.opacity(0.85)) }
                    Spacer()
                }
                .padding(.top, 8)
                .rotationEffect(.degrees(Double(n) / Double(Self.numbers) * 360))
            }
            Circle().fill(Color(white: 0.18)).frame(width: 90, height: 90).overlay(Circle().stroke(Color(white: 0.4), lineWidth: 2))
            Text(String(format: "%02d", dialNumber)).font(.system(size: 30, weight: .heavy, design: .monospaced))
        }
        .rotationEffect(.degrees(-Double(dialNumber) / Double(Self.numbers) * 360))
        .animation(.spring(duration: 0.15), value: dialNumber)
        .overlay(alignment: .top) {
            Image(systemName: "arrowtriangle.down.fill").font(.title2).foregroundStyle(Theme.warn).offset(y: -14)
        }
        .frame(width: 280, height: 280)
    }

    private func lockIn() {
        guard !opened else { return }
        if dialNumber == combination[step] {
            step += 1
            if step == combination.count {
                opened = true
                openedIn = Date().timeIntervalSince(startedAt)
                engine.pattern([(60, 200, 60), (60, 230, 60), (60, 255, 120), (300, 255, 0)])
            } else {
                engine.pattern([(40, 220, 50), (40, 220, 0)])
            }
        } else {
            shake += 1
            step = 0
            engine.pattern([(250, 255, 0)])
        }
    }

    private func reset() {
        combination = Self.newCombination()
        step = 0
        opened = false
        openedIn = nil
        startedAt = Date()
        engine.calibrateTwist()
        engine.pattern([(30, 150, 50), (30, 150, 0)])
    }
}

private struct Shake: GeometryEffect {
    var amount: CGFloat
    var animatableData: CGFloat {
        get { amount }
        set { amount = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 10 * sin(amount * .pi * 6), y: 0))
    }
}
