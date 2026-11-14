import BandKit
import BandLogging
import BandProtocol
import SwiftUI

/// An original Flappy-style game: index taps flap (single or double), a middle-finger hold restarts.
@MainActor
@Observable
final class FlappyGame {
    enum State { case ready, playing, over }
    struct Pipe: Identifiable { let id = UUID(); var x: Double; let gapCenter: Double; var scored = false }

    private(set) var state = State.ready
    private(set) var birdY = 0.5
    private(set) var velocity = 0.0
    private(set) var pipes: [Pipe] = []
    private(set) var score = 0
    private(set) var best = UserDefaults.standard.integer(forKey: "flappy.best")
    private(set) var flapCount = 0
    /// How far the world has scrolled (for the ground stripes and clouds).
    private(set) var distance = 0.0
    var onScore: (() -> Void)?
    var onCrash: (() -> Void)?
    @ObservationIgnored private var lastTime: Date?
    @ObservationIgnored private var aspect = 0.5

    // World units: height = 1, width = aspect.
    let birdX = 0.28
    let birdRadius = 0.022
    let gravity = 2.6
    let flapVelocity = -0.78
    let speed = 0.32
    let gap = 0.27
    let pipeWidth = 0.13
    let spacing = 0.58

    func setAspect(_ value: Double) { aspect = max(0.3, value) }

    func flap() {
        switch state {
        case .ready:
            state = .playing
            velocity = flapVelocity
        case .playing:
            velocity = flapVelocity
        case .over:
            return
        }
        flapCount += 1
    }

    func restart() {
        state = .ready
        birdY = 0.5
        velocity = 0
        pipes = []
        score = 0
        lastTime = nil
        logInfo(.games, "Flappy restarted")
    }

    func step(to date: Date) {
        defer { lastTime = date }
        guard let last = lastTime else { return }
        let dt = min(1.0 / 20, date.timeIntervalSince(last))
        guard state == .playing else {
            if state == .ready { birdY = 0.5 + sin(date.timeIntervalSinceReferenceDate * 3) * 0.015 }
            return
        }
        distance += speed * dt
        velocity += gravity * dt
        birdY += velocity * dt
        for index in pipes.indices { pipes[index].x -= speed * dt }
        pipes.removeAll { $0.x < -pipeWidth }
        if pipes.last.map({ $0.x < aspect + pipeWidth - spacing }) ?? true {
            pipes.append(Pipe(x: aspect + pipeWidth, gapCenter: Double.random(in: 0.25...0.72)))
        }
        for index in pipes.indices where !pipes[index].scored && pipes[index].x + pipeWidth < birdX * aspect {
            pipes[index].scored = true
            score += 1
            onScore?()
        }
        if collided() {
            state = .over
            if score > best {
                best = score
                UserDefaults.standard.set(best, forKey: "flappy.best")
            }
            logInfo(.games, "Flappy crash at score \(score)")
            onCrash?()
        }
    }

    private func collided() -> Bool {
        let ground = 0.92
        if birdY + birdRadius > ground || birdY - birdRadius < 0 { return true }
        let x = birdX * aspect
        for pipe in pipes where x + birdRadius > pipe.x && x - birdRadius < pipe.x + pipeWidth {
            if birdY - birdRadius < pipe.gapCenter - gap / 2 || birdY + birdRadius > pipe.gapCenter + gap / 2 { return true }
        }
        return false
    }
}

struct FlappyView: View {
    @Environment(BandClient.self) private var band
    @Environment(AppModel.self) private var model
    @State private var game = FlappyGame()
    @State private var input = GameInput.band
    @State private var haptics = true
    @State private var lastSource: EventSource?
    @State private var flapPulse = 0

    var body: some View {
        VStack(spacing: 0) {
            controls
            GeometryReader { geometry in
                TimelineView(.animation) { timeline in
                    Canvas { context, size in draw(&context, size) }
                        .onChange(of: timeline.date) { _, date in game.step(to: date) }
                }
                .onAppear { game.setAspect(geometry.size.width / max(1, geometry.size.height)) }
                .onChange(of: geometry.size) { _, size in game.setAspect(size.width / max(1, size.height)) }
                .overlay(alignment: .top) { hud }
                .overlay { overlayText }
                .contentShape(Rectangle())
                .onTapGesture { if input == .touch { lastSource = .touch; game.flap(); flapPulse += 1 } }
                .onLongPressGesture(minimumDuration: 0.6) { if input == .touch { lastSource = .touch; game.restart() } }
            }
            .clipShape(RoundedRectangle(cornerRadius: 24))
            .padding()
        }
        .screenBackground()
        .navigationTitle("Flappy Band")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { ConnectionPill() } }
        .onAppear {
            game.onScore = { if haptics { Task { await band.haptic(.vibrate(durationMs: 35, amplitude: 140)) } } }
            game.onCrash = { if haptics { Task { await band.haptic(.vibrate(durationMs: 260, amplitude: 255)) } } }
        }
        .task {
            for await event in band.events.subscribe() {
                guard case .gesture(let gesture) = event else { continue }
                handle(gesture)
            }
        }
    }

    private func handle(_ event: GestureEvent) {
        // Band input: real band events, plus simulated ones only while simulation mode is on (labeled).
        guard input == .band, event.source == .band || (event.source == .simulated && model.simulationEnabled) else { return }
        switch event.gesture {
        case .tap(.index, .tap):
            lastSource = event.source
            game.flap()
            flapPulse += 1
        case .tap(.index, .doubleTap):
            // Fast tapping reads as a double tap: that's two flaps, never a restart.
            lastSource = event.source
            game.flap()
            flapPulse += 1
            Task { try? await Task.sleep(for: .milliseconds(90)); game.flap() }
        case .tap(.middle, .hold):
            lastSource = event.source
            game.restart()
        default: break
        }
    }

    private var controls: some View {
        VStack(spacing: 8) {
            Picker("Input", selection: $input) {
                ForEach(GameInput.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            HStack {
                Toggle("Band haptics on score / crash", isOn: $haptics).font(.footnote)
                    .disabled(band.phase != .streaming)
            }
            if input == .band, band.phase != .streaming, !model.simulationEnabled {
                Text("Waiting for the band. Connect on the Band tab, or switch to Touch.").font(.caption).foregroundStyle(Theme.warn)
            }
        }
        .padding(.horizontal)
        .padding(.top, 8)
    }

    private var hud: some View {
        HStack {
            Text("\(game.score)").font(.system(size: 44, weight: .black, design: .monospaced))
                .shadow(color: .black, radius: 0, x: 3, y: 3)
                .contentTransition(.numericText()).animation(.snappy, value: game.score)
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text("Best \(game.best)").font(.caption.bold())
                if let lastSource { SourceBadge(source: lastSource) } else {
                    Text(input == .band ? "Index tap to flap" : "Tap to flap").badgeStyle(.gray)
                }
            }
        }
        .padding()
        .foregroundStyle(.white)
    }

    @ViewBuilder private var overlayText: some View {
        switch game.state {
        case .ready:
            message(input == .band ? "Index tap to start" : "Tap to start", input == .band ? "Hold your middle finger to restart" : "Long-press to restart")
        case .over:
            message("GAME OVER", input == .band ? "Hold your middle finger to restart" : "Long-press to restart")
        case .playing:
            EmptyView()
        }
    }

    private func message(_ title: String, _ detail: String) -> some View {
        VStack(spacing: 6) {
            Text(title).font(.title.bold())
            Text(detail).font(.callout).foregroundStyle(.white.opacity(0.8))
        }
        .padding(20)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
        .allowsHitTesting(false)
    }

    // MARK: pixel-art rendering (original art in the classic style)

    /// 17×12 bird sprite: Y body, W eye white, K pupil/outline, O beak, R wing, . transparent.
    private static let birdSprite = [
        "......KKKKKK.....",
        "....KKYYYKWWK....",
        "...KYYYYKWWWWK...",
        "..KYYYYYKWWWKWK..",
        ".KYYYYYYKWWWKWK..",
        ".KRRRRYYYKWWWWK..",
        "KRRRRRRYYYKKKKKK.",
        "KRRRRRRYYKOOOOOOK",
        ".KRRRRYYKOKKKKKK.",
        "..KYYYYYYKOOOOOK.",
        "...KKYYYYYKKKKK..",
        ".....KKKKK.......",
    ]

    private static let palette: [Character: Color] = [
        "Y": Color(red: 0.98, green: 0.82, blue: 0.15), "W": .white, "K": Color(red: 0.2, green: 0.13, blue: 0.1),
        "O": Color(red: 0.95, green: 0.45, blue: 0.12), "R": Color(red: 0.98, green: 0.95, blue: 0.85),
    ]

    private func draw(_ context: inout GraphicsContext, _ size: CGSize) {
        let h = size.height
        let px = max(2, (h / 160).rounded())  // one "pixel"
        func snap(_ value: CGFloat) -> CGFloat { (value / px).rounded() * px }

        // Sky in flat bands.
        let bands: [Color] = [Color(red: 0.31, green: 0.75, blue: 0.82), Color(red: 0.35, green: 0.78, blue: 0.84),
                              Color(red: 0.42, green: 0.81, blue: 0.86), Color(red: 0.5, green: 0.84, blue: 0.88)]
        for (index, color) in bands.enumerated() {
            let top = snap(h * 0.92 * CGFloat(index) / CGFloat(bands.count))
            context.fill(Path(CGRect(x: 0, y: top, width: size.width, height: snap(h * 0.92 / CGFloat(bands.count)) + px)), with: .color(color))
        }

        // Pixel clouds drifting slowly.
        let cloudShape = ["..WWW.....", ".WWWWWWW..", "WWWWWWWWWW", ".WWWWWWWW."]
        for i in 0..<4 {
            let span = size.width + 14 * px * 10
            let x = (CGFloat(i) * span / 4 - CGFloat(game.distance) * h * 0.08).truncatingRemainder(dividingBy: span)
            let cx = snap(x < -14 * px * 10 ? x + span : x)
            let cy = snap(h * (0.12 + 0.09 * CGFloat(i % 2)))
            for (row, line) in cloudShape.enumerated() {
                for (column, char) in line.enumerated() where char == "W" {
                    context.fill(Path(CGRect(x: cx + CGFloat(column) * px * 2, y: cy + CGFloat(row) * px * 2, width: px * 2, height: px * 2)),
                                 with: .color(.white.opacity(0.85)))
                }
            }
        }

        // Pipes: body with a light stripe and dark edge, a wider lip at the gap.
        let pipeGreen = Color(red: 0.45, green: 0.75, blue: 0.18)
        let pipeLight = Color(red: 0.62, green: 0.88, blue: 0.3)
        let pipeDark = Color(red: 0.25, green: 0.5, blue: 0.1)
        let outline = Color(red: 0.2, green: 0.25, blue: 0.1)
        for pipe in game.pipes {
            let x = snap(pipe.x * h)
            let width = snap(game.pipeWidth * h)
            let gapTop = snap((pipe.gapCenter - game.gap / 2) * h)
            let gapBottom = snap((pipe.gapCenter + game.gap / 2) * h)
            let lip = 6 * px
            for (top, bottom, lipY) in [(CGFloat(0), gapTop, gapTop - lip), (gapBottom, h * 0.92, gapBottom)] {
                let body = CGRect(x: x + px, y: top, width: width - 2 * px, height: bottom - top)
                context.fill(Path(body.insetBy(dx: -px, dy: 0)), with: .color(outline))
                context.fill(Path(body), with: .color(pipeGreen))
                context.fill(Path(CGRect(x: body.minX + 2 * px, y: top, width: 2 * px, height: bottom - top)), with: .color(pipeLight))
                context.fill(Path(CGRect(x: body.maxX - 3 * px, y: top, width: 2 * px, height: bottom - top)), with: .color(pipeDark))
                let lipRect = CGRect(x: x - 2 * px, y: lipY, width: width + 4 * px, height: lip)
                context.fill(Path(lipRect.insetBy(dx: -px, dy: -px)), with: .color(outline))
                context.fill(Path(lipRect), with: .color(pipeGreen))
                context.fill(Path(CGRect(x: lipRect.minX + 2 * px, y: lipRect.minY, width: 2 * px, height: lip)), with: .color(pipeLight))
                context.fill(Path(CGRect(x: lipRect.maxX - 3 * px, y: lipRect.minY, width: 2 * px, height: lip)), with: .color(pipeDark))
            }
        }

        // Ground: grass strip and scrolling diagonal stripes.
        let groundTop = snap(h * 0.92)
        context.fill(Path(CGRect(x: 0, y: groundTop, width: size.width, height: h - groundTop)), with: .color(Color(red: 0.87, green: 0.84, blue: 0.58)))
        context.fill(Path(CGRect(x: 0, y: groundTop, width: size.width, height: 2 * px)), with: .color(outline))
        context.fill(Path(CGRect(x: 0, y: groundTop + 2 * px, width: size.width, height: 3 * px)), with: .color(Color(red: 0.55, green: 0.85, blue: 0.25)))
        let stripe = 8 * px
        let offset = CGFloat(game.distance * h).truncatingRemainder(dividingBy: stripe * 2)
        var sx = -offset
        while sx < size.width {
            for row in 0..<3 {
                context.fill(Path(CGRect(x: snap(sx + CGFloat(row) * px * 2), y: groundTop + (5 + CGFloat(row)) * px, width: stripe, height: px)),
                             with: .color(Color(red: 0.6, green: 0.88, blue: 0.3)))
            }
            sx += stripe * 2
        }

        // The bird, rotated with its velocity, drawn pixel by pixel.
        let center = CGPoint(x: snap(game.birdX * size.width), y: snap(game.birdY * h))
        let tilt = Angle(radians: max(-0.45, min(1.2, game.velocity * 1.2)))
        let scale = (game.birdRadius * h * 2.6) / 17
        var bird = context
        bird.translateBy(x: center.x, y: center.y)
        bird.rotate(by: tilt)
        let flapUp = game.state == .playing && Int(game.distance * 30) % 2 == 0
        for (row, line) in Self.birdSprite.enumerated() {
            for (column, char) in line.enumerated() {
                guard var color = Self.palette[char] else { continue }
                if char == "R" && flapUp { color = Color(red: 0.98, green: 0.88, blue: 0.4) }
                let rect = CGRect(x: (CGFloat(column) - 8.5) * scale, y: (CGFloat(row) - 6) * scale, width: scale + 0.5, height: scale + 0.5)
                bird.fill(Path(rect), with: .color(color))
            }
        }
    }
}
