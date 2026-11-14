import BandKit
import BandProtocol
import SwiftUI

/// Wrist Pong: turn your wrist like a doorknob to move the paddle. Middle hold restarts.
@MainActor
@Observable
final class PongGame {
    var ball = CGPoint(x: 0.5, y: 0.5)
    var velocity = CGVector(dx: 0.25, dy: 0.45)
    var player = 0.5
    var opponent = 0.5
    var playerScore = 0
    var opponentScore = 0
    var winner: String?
    let paddleWidth = 0.24
    var onPaddleHit: (() -> Void)?
    var onMiss: (() -> Void)?
    var onPoint: (() -> Void)?
    @ObservationIgnored private var last: Date?

    func restart() {
        playerScore = 0
        opponentScore = 0
        winner = nil
        serve(towardPlayer: true)
    }

    func serve(towardPlayer: Bool) {
        ball = CGPoint(x: 0.5, y: 0.5)
        let angle = Double.random(in: -0.6...0.6)
        velocity = CGVector(dx: sin(angle) * 0.5, dy: (towardPlayer ? 1 : -1) * cos(angle) * 0.5)
        last = nil
    }

    func step(to date: Date, aspect: Double) {
        defer { last = date }
        guard let last, winner == nil else { return }
        let dt = min(1.0 / 30, date.timeIntervalSince(last))
        // Opponent: follows the ball with a speed limit, so it can be beaten.
        let maxSpeed = 0.55 + 0.03 * Double(playerScore)
        opponent += max(-maxSpeed * dt, min(maxSpeed * dt, ball.x - opponent))
        ball.x += velocity.dx * dt
        ball.y += velocity.dy * dt * aspect
        if ball.x < 0.02 || ball.x > 0.98 {
            velocity.dx = -velocity.dx
            ball.x = min(0.98, max(0.02, ball.x))
        }
        // Player paddle (bottom).
        if velocity.dy > 0, ball.y >= 0.92, ball.y <= 0.96, abs(ball.x - player) <= paddleWidth / 2 + 0.02 {
            bounce(off: player, up: true)
            onPaddleHit?()
        }
        // Opponent paddle (top).
        if velocity.dy < 0, ball.y <= 0.08, ball.y >= 0.04, abs(ball.x - opponent) <= paddleWidth / 2 + 0.02 {
            bounce(off: opponent, up: false)
        }
        if ball.y > 1.02 {
            opponentScore += 1
            onMiss?()
            finishOrServe(towardPlayer: true)
        } else if ball.y < -0.02 {
            playerScore += 1
            onPoint?()
            finishOrServe(towardPlayer: false)
        }
    }

    private func bounce(off paddle: Double, up: Bool) {
        let offset = (ball.x - paddle) / (paddleWidth / 2) // −1…1
        let speed = min(1.3, hypot(velocity.dx, velocity.dy) * 1.05)
        let angle = offset * 1.0
        velocity = CGVector(dx: sin(angle) * speed, dy: (up ? -1 : 1) * cos(angle) * speed)
    }

    private func finishOrServe(towardPlayer: Bool) {
        if playerScore >= 7 { winner = "You win!" } else if opponentScore >= 7 { winner = "Computer wins" } else { serve(towardPlayer: towardPlayer) }
    }
}

struct PongView: View {
    @Environment(BandClient.self) private var band
    @Environment(AppModel.self) private var model
    @State private var game = PongGame()
    @State private var range = 35.0
    @State private var touchControl = false

    private var engine: MotionEngine { model.motion }

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text("\(game.opponentScore)").font(.system(size: 34, weight: .heavy, design: .rounded))
                Spacer()
                VStack {
                    Text(touchControl ? "Touch" : String(format: "Twist %+.0f°", engine.twist)).font(.caption.monospacedDigit())
                    Button("Center wrist") { engine.calibrateTwist() }.font(.caption).buttonStyle(.bordered)
                }
                Spacer()
                Text("\(game.playerScore)").font(.system(size: 34, weight: .heavy, design: .rounded)).foregroundStyle(Theme.mint)
            }
            GeometryReader { geometry in
                TimelineView(.animation) { timeline in
                    Canvas { context, size in
                        draw(&context, size)
                    }
                    .onChange(of: timeline.date) { _, date in
                        if !touchControl {
                            game.player = min(1 - game.paddleWidth / 2, max(game.paddleWidth / 2, 0.5 + engine.twist / range * 0.5))
                        }
                        game.step(to: date, aspect: geometry.size.width / max(1, geometry.size.height))
                    }
                }
                .background(RoundedRectangle(cornerRadius: 20).fill(Color.black.opacity(0.55)))
                .overlay {
                    if let winner = game.winner {
                        VStack(spacing: 8) {
                            Text(winner).font(.title.bold())
                            Text("Hold your middle finger to play again").font(.callout).foregroundStyle(.secondary)
                        }
                        .padding(20).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                    } else if !engine.hasOrientation && !touchControl {
                        Text("Connect the band, or turn on touch control").font(.callout).padding()
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    guard touchControl else { return }
                    game.player = min(1 - game.paddleWidth / 2, max(game.paddleWidth / 2, value.location.x / geometry.size.width))
                })
            }
            VStack(spacing: 6) {
                HStack {
                    Text("Turn range ±\(Int(range))°").font(.caption)
                    Slider(value: $range, in: 15...70)
                }
                HStack {
                    Toggle("Invert twist", isOn: Binding(get: { engine.invertTwist }, set: { engine.invertTwist = $0 })).font(.caption)
                    Toggle("Touch control", isOn: $touchControl).font(.caption)
                }
            }
        }
        .padding()
        .screenBackground()
        .navigationTitle("Wrist Pong")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { ConnectionPill() } }
        .onAppear {
            engine.calibrateTwist()
            game.onPaddleHit = { engine.tick(durationMs: 35, amplitude: 210, spacing: 0) }
            game.onMiss = { engine.pattern([(220, 255, 0)]) }
            game.onPoint = { engine.pattern([(40, 180, 60), (40, 230, 0)]) }
            game.restart()
        }
        .task {
            for await event in band.events.subscribe() {
                guard case .gesture(let gesture) = event, gesture.source == .band || model.simulationEnabled else { continue }
                if gesture.gesture == .tap(.middle, .hold) {
                    engine.calibrateTwist()
                    game.restart()
                }
            }
        }
    }

    private func draw(_ context: inout GraphicsContext, _ size: CGSize) {
        // Dashed center line.
        var x: CGFloat = 6
        while x < size.width {
            context.fill(Path(CGRect(x: x, y: size.height / 2 - 1, width: 10, height: 2)), with: .color(.white.opacity(0.18)))
            x += 20
        }
        let paddleSize = CGSize(width: game.paddleWidth * size.width, height: 12)
        let opponentRect = CGRect(x: game.opponent * size.width - paddleSize.width / 2, y: 0.06 * size.height - paddleSize.height / 2, width: paddleSize.width, height: paddleSize.height)
        let playerRect = CGRect(x: game.player * size.width - paddleSize.width / 2, y: 0.94 * size.height - paddleSize.height / 2, width: paddleSize.width, height: paddleSize.height)
        context.fill(Path(roundedRect: opponentRect, cornerRadius: 6), with: .color(.white.opacity(0.8)))
        context.fill(Path(roundedRect: playerRect, cornerRadius: 6), with: .color(Theme.mint))
        let ballRect = CGRect(x: game.ball.x * size.width - 9, y: game.ball.y * size.height - 9, width: 18, height: 18)
        context.fill(Path(ellipseIn: ballRect), with: .color(.white))
    }
}
