import BandKit
import BandProtocol
import SwiftUI

enum Theme {
    static let accent = Color(red: 0.38, green: 0.58, blue: 1.0)
    static let mint = Color(red: 0.2, green: 0.85, blue: 0.65)
    static let warn = Color(red: 1.0, green: 0.72, blue: 0.25)
    static let danger = Color(red: 1.0, green: 0.38, blue: 0.42)
    static let card = Color.white.opacity(0.06)
    static let background = LinearGradient(colors: [Color(red: 0.05, green: 0.06, blue: 0.12), Color(red: 0.02, green: 0.02, blue: 0.05)],
                                           startPoint: .top, endPoint: .bottom)

    static func color(for phase: ConnectionPhase) -> Color {
        switch phase {
        case .streaming: mint
        case .failed: danger
        case .bluetoothUnavailable: danger
        case .idle: .gray
        case .reconnecting, .pairingPrompt: warn
        default: accent
        }
    }

    static func symbol(for phase: ConnectionPhase) -> String {
        switch phase {
        case .streaming: "dot.radiowaves.left.and.right"
        case .failed: "exclamationmark.triangle.fill"
        case .bluetoothUnavailable: "antenna.radiowaves.left.and.right.slash"
        case .idle: "circle.dashed"
        case .reconnecting: "arrow.triangle.2.circlepath"
        case .pairingPrompt: "hand.raised.fill"
        case .claiming: "key.fill"
        default: "antenna.radiowaves.left.and.right"
        }
    }

    static func color(for gesture: RecognizedGesture) -> Color {
        switch gesture {
        case .swipe: Color(red: 0.75, green: 0.5, blue: 1)
        case .tap(.index, _): accent
        case .tap(.middle, _): mint
        }
    }

    static func symbol(for gesture: RecognizedGesture) -> String {
        switch gesture {
        case .swipe(.left): "arrow.left"
        case .swipe(.right): "arrow.right"
        case .swipe(.up): "arrow.up"
        case .swipe(.down): "arrow.down"
        case .tap(_, .tap): "hand.tap"
        case .tap(_, .doubleTap): "hand.tap.fill"
        case .tap(_, .hold): "hand.point.up.left.fill"
        }
    }
}

struct Card<Content: View>: View {
    var title: String?
    var systemImage: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                Label(title, systemImage: systemImage ?? "circle")
                    .font(.footnote.weight(.semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(.white.opacity(0.06)))
    }
}

struct InfoRow: View {
    let label: String
    let value: String
    var monospaced = false

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .font(monospaced ? .callout.monospaced() : .callout)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .font(.callout)
    }
}

struct SourceBadge: View {
    let source: EventSource

    var body: some View {
        switch source {
        case .band:
            Label("Neural Band", systemImage: "wave.3.right").badgeStyle(Theme.mint)
        case .simulated:
            Label("SIMULATED", systemImage: "theatermasks").badgeStyle(Theme.warn)
        case .touch:
            Label("Touch", systemImage: "hand.point.up").badgeStyle(.gray)
        }
    }
}

extension View {
    func badgeStyle(_ color: Color) -> some View {
        font(.caption2.weight(.bold))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }

    func screenBackground() -> some View {
        background(Theme.background.ignoresSafeArea())
    }
}

/// A compact connection status pill for screens other than the Band tab.
struct ConnectionPill: View {
    @Environment(BandClient.self) private var band

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(Theme.color(for: band.phase)).frame(width: 8, height: 8)
            Text(band.phase == .streaming ? "Band live" : band.phase.title).lineLimit(1)
            if let battery = band.battery { Text("· \(battery)%").foregroundStyle(.secondary) }
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
    }
}
