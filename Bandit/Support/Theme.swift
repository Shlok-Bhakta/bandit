import SwiftUI
import UIKit

/// Bandit's look (the demo app's Theme, without the band-specific parts).
enum Theme {
    /// The app's accent: the one picked in Settings › Appearance, else blue.
    static var accent: Color { color(hex: UserDefaults.standard.string(forKey: Appearance.accentKey)) ?? blue }
    static let blue = Color(red: 0.38, green: 0.58, blue: 1.0)
    static let mint = Color(red: 0.2, green: 0.85, blue: 0.65)
    static let warn = Color(red: 1.0, green: 0.72, blue: 0.25)
    static let danger = Color(red: 1.0, green: 0.38, blue: 0.42)
    static let violet = Color(red: 0.75, green: 0.5, blue: 1)
    static let card = Color.white.opacity(0.06)
    static let background = LinearGradient(colors: [Color(red: 0.05, green: 0.06, blue: 0.12), Color(red: 0.02, green: 0.02, blue: 0.05)],
                                           startPoint: .top, endPoint: .bottom)

    /// Colours a profile can carry (`color` in the file), by name in the editor.
    static let profileColors: [(name: String, hex: String)] = [
        ("Blue", "#6194ff"), ("Mint", "#33d9a6"), ("Amber", "#ffb840"), ("Coral", "#ff616b"),
        ("Violet", "#bf80ff"), ("Pink", "#ff7ac6"), ("Sky", "#4cc9f0"), ("Lime", "#a6e05a"),
    ]

    /// `#rrggbb` → a colour (nil for anything else).
    static func color(hex: String?) -> Color? {
        guard var text = hex?.trimmingCharacters(in: .whitespaces), text.hasPrefix("#") else { return nil }
        text.removeFirst()
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        return Color(red: Double(value >> 16 & 0xFF) / 255, green: Double(value >> 8 & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
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

    /// A List styled like the rest of the app.
    func darkList() -> some View {
        scrollContentBackground(.hidden).screenBackground()
    }
}

/// What Settings › Appearance changes (UserDefaults: nothing secret).
enum Appearance {
    static let accentKey = "appearance.accent"
    /// The Dongle tab's glow takes the active profile's colour (else the accent's).
    static let glowKey = "appearance.profileGlow"
}

/// Slowly drifting blurred light: the glow behind the hero cards. Still with Reduce Motion.
struct Aurora: View {
    var colors: [Color]
    var speed = 1.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
            let t = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate * 0.35 * speed
            GeometryReader { geometry in
                let size = geometry.size
                ZStack {
                    ForEach(Array(colors.prefix(3).enumerated()), id: \.offset) { index, color in
                        let phase = Double(index) * 2.1
                        Circle()
                            .fill(color)
                            .frame(width: size.width * 0.9, height: size.width * 0.9)
                            .offset(x: cos(t + phase) * size.width * 0.28, y: sin(t * 1.3 + phase) * size.height * 0.3)
                            .opacity(0.55)
                    }
                }
                .frame(width: size.width, height: size.height)
                .blur(radius: 50)
            }
        }
        .allowsHitTesting(false)
    }
}

/// A rounded card with a coloured glow behind glass.
struct GlowCard<Content: View>: View {
    var tint: Color
    var cornerRadius: CGFloat = 28
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                ZStack {
                    Color(red: 0.06, green: 0.07, blue: 0.13)
                    Aurora(colors: [tint, tint.mix(with: Theme.violet, by: 0.5), tint.mix(with: Theme.mint, by: 0.4)])
                    LinearGradient(colors: [.clear, .black.opacity(0.35)], startPoint: .top, endPoint: .bottom)
                }
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            }
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(LinearGradient(colors: [.white.opacity(0.28), tint.opacity(0.25), .white.opacity(0.04)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1))
            .shadow(color: tint.opacity(0.35), radius: 24, y: 10)
    }
}

/// An SF Symbol in a tinted rounded tile, the app's icon look.
struct SymbolTile: View {
    let symbol: String
    var tint: Color
    var size: CGFloat = 36

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(LinearGradient(colors: [tint, tint.mix(with: .black, by: 0.35)], startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
            .shadow(color: tint.opacity(0.4), radius: size * 0.15, y: size * 0.06)
    }
}

/// Scales down a little while pressed.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

extension Color {
    /// iOS 18's Color.mix, with a plain blend before it.
    func mix(with other: Color, by fraction: Double) -> Color {
        if #available(iOS 18, *) { return mix(with: other, by: fraction, in: .perceptual) }
        let a = UIColor(self).rgba, b = UIColor(other).rgba
        return Color(red: a.r + (b.r - a.r) * fraction, green: a.g + (b.g - a.g) * fraction, blue: a.b + (b.b - a.b) * fraction, opacity: a.a + (b.a - a.a) * fraction)
    }
}

private extension UIColor {
    var rgba: (r: Double, g: Double, b: Double, a: Double) {
        var (r, g, b, a): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return (r, g, b, a)
    }
}
