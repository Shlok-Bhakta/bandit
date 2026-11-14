import BandKit
import BandProtocol
import SwiftUI

struct GamesView: View {
    @Environment(BandClient.self) private var band

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                NavigationLink { BandExplorerView() } label: {
                    gameCard("Band Explorer", "Everything the band exposes: a demo per capability, every setting, update status, experimental streams, every message type.", "binoculars.fill", [Theme.mint, Theme.accent])
                }
                .buttonStyle(.plain)
                NavigationLink { HandwritingView() } label: {
                    gameCard("Handwriting", "The band's own letter recognizer. Write with your finger, watch the letters and the raw scores.", "pencil.and.scribble", [Color.pink, Color.purple])
                }
                .buttonStyle(.plain)
                NavigationLink { SafeCrackerView() } label: {
                    gameCard("Safe Cracker", "Twist your wrist to turn the dial. Feel every click on the band; the right number thunks.", "lock.rotation", [Color.orange, Color.red])
                }
                .buttonStyle(.plain)
                NavigationLink { CursorLabView() } label: {
                    gameCard("Air Cursor", "Pinch, hold and move your forearm to steer. Tap to click. Targets, air drawing, buttons.", "cursorarrow.motionlines", [Theme.accent, Color.purple])
                }
                .buttonStyle(.plain)
                NavigationLink { PongView() } label: {
                    gameCard("Wrist Pong", "Turn your wrist like a doorknob to move the paddle.", "circle.and.line.horizontal", [Color.cyan, Theme.mint])
                }
                .buttonStyle(.plain)
                NavigationLink { Game2048View() } label: {
                    gameCard("2048", "Thumb swipes slide the tiles. Bigger merges buzz harder.", "square.grid.2x2.fill", [Color.yellow, Color.orange])
                }
                .buttonStyle(.plain)
                NavigationLink { FlappyView() } label: {
                    gameCard("Flappy Band", "Index tap to flap. Hold your middle finger to restart.", "bird.fill", [Theme.accent, Theme.mint])
                }
                .buttonStyle(.plain)
                NavigationLink { ReactionView() } label: {
                    gameCard("Reaction time", "Tap the moment the target appears. Measures your reflexes plus the band's latency.", "timer", [Theme.warn, Theme.danger])
                }
                .buttonStyle(.plain)
                if band.phase != .streaming {
                    Label("The games read real band events. Connect your band on the Band tab, or use Touch mode inside a game for testing.", systemImage: "info.circle")
                        .font(.footnote).foregroundStyle(.secondary).padding(.horizontal)
                }
            }
            .padding()
        }
        .screenBackground()
        .navigationTitle("Games")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { ConnectionPill() } }
    }

    private func gameCard(_ title: String, _ detail: String, _ symbol: String, _ colors: [Color]) -> some View {
        HStack(spacing: 16) {
            Image(systemName: symbol).font(.system(size: 34)).frame(width: 64, height: 64)
                .background(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 16))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.title3.bold())
                Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.leading)
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(.secondary)
        }
        .padding()
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 20))
        .foregroundStyle(.primary)
    }
}

/// Which inputs a game listens to. Band is the default; the others are labeled on screen.
enum GameInput: String, CaseIterable, Identifiable {
    case band = "Neural Band"
    case touch = "Touch"
    var id: Self { self }
}
