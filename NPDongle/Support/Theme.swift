import SwiftUI

/// Neural Playground's look (the demo app's Theme, without the band-specific parts).
enum Theme {
    static let accent = Color(red: 0.38, green: 0.58, blue: 1.0)
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
