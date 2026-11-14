import Foundation

public struct Pulse: Equatable, Sendable {
    public var atMS: Int
    public var ms: Int
    public var strength: Int
    public var amplitude: Int { (strength * 255 + 50) / 100 }
}
public struct Pattern: Equatable, Sendable {
    public var pulses: [Pulse]
    public var duration: Int { pulses.last.map { $0.atMS + $0.ms } ?? 0 }
}
public struct BuzzFeedback: Sendable {
    public let name: String
    public let pattern: String
    public let detail: String
    public static let all: [Self] = [
        .init(name: "connected", pattern: "tap", detail: "Band connected"),
        .init(name: "refused", pattern: "long", detail: "Action refused or unavailable"),
        .init(name: "host.phone", pattern: "tap", detail: "Switched to a phone"),
        .init(name: "host.computer", pattern: "double", detail: "Switched to a computer or TV"),
        .init(name: "alert.done", pattern: "done", detail: "Helper finished"),
        .init(name: "alert.question", pattern: "question", detail: "Helper has a question"),
        .init(name: "alert.error", pattern: "error", detail: "Helper failed"),
        .init(name: "call.ringing", pattern: "ring", detail: "Incoming iPhone call"),
        .init(name: "write.on", pattern: "double", detail: "Handwriting started"),
        .init(name: "write.off", pattern: "tap", detail: "Handwriting stopped"),
        .init(name: "menu.ready", pattern: "double", detail: "Ready for a menu letter"),
        .init(name: "hold.start", pattern: "tick", detail: "Middle hold started"),
        .init(name: "gesture", pattern: "none", detail: "A gesture ran an action"),
    ]
}
extension ProfileFormat {
    public static let builtinBuzzes: [(name: String, text: String)] = [
        ("tick", "40*55"),
        ("tap", "60*63"),
        ("double", "60*63 _190 60*63"),
        ("triple", "60*63 _190 60*63 _190 60*63"),
        ("quad", "60*63 _190 60*63 _190 60*63 _190 60*63"),
        ("long", "400*78"),
        ("done", "250*78 _200 250*78"),
        ("question", "70*67 _130 70*67 _130 380*86"),
        ("error", "900*90"),
        ("ring", "600*90 _300 600*90"),
        ("heartbeat", "90*85 _110 70*45"),
        ("rise", "60*30 _90 60*55 _90 60*80 _90 80*100"),
        ("fall", "80*100 _90 60*80 _90 60*55 _90 60*30"),
        ("nudge", "30*50"),
    ]
    public static func findBuzz(_ name: String, buzzes: [String: Pattern] = [:], path: String = "") throws -> Pattern {
        if let pattern = buzzes[name] { return pattern }
        if let text = builtinBuzzes.first(where: { $0.name == name })?.text { return try parsePattern(text, path: path) }
        throw ProfileError(path, "no buzz pattern \"\(name)\" (the file's buzzes, or one of \(builtinBuzzes.map(\.name).joined(separator: ", ")))")
    }
    public static func parsePattern(_ text: String, path: String = "") throws -> Pattern {
        let how = "a pattern is pulses (ms, or ms*strength 1–100) and pauses (_ms), like \"250 _200 250*90\""
        func fail(_ message: String) -> ProfileError { ProfileError(path, message) }
        func number(_ text: Substring) -> Int? {
            guard !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }), let n = UInt32(text) else { return nil }
            return Int(n)
        }
        if text.utf8.count > 120 { throw fail("a pattern is at most 120 characters") }
        let tokens = text.split { $0.isASCII && [" ", "\t", "\n", "\r", "\u{0C}"].contains($0) }
        if tokens.isEmpty { throw fail(how) }
        if tokens.count > 16 { throw fail("at most 16 pulses and pauses") }
        var pulses: [Pulse] = []
        var at = 0
        var lastPause = false
        for (i, token) in tokens.enumerated() {
            if token.first == "_" {
                guard let ms = number(token.dropFirst()) else { throw fail(how) }
                guard (20...3000).contains(ms) else { throw fail("a pause is 20–3000 ms") }
                if i == 0 || lastPause { throw fail("a pause goes between two pulses") }
                at += ms
                lastPause = true
            } else {
                let parts = token.split(separator: "*", maxSplits: 1, omittingEmptySubsequences: false)
                var strength = 70
                if parts.count == 2 {
                    guard let n = number(parts[1]), (1...100).contains(n) else { throw fail("strength is 1–100") }
                    strength = n
                }
                guard let ms = number(parts[0]) else { throw fail(how) }
                guard (20...2000).contains(ms) else { throw fail("a pulse is 20–2000 ms") }
                pulses.append(Pulse(atMS: at, ms: ms, strength: strength))
                at += ms
                lastPause = false
            }
            if at > 8000 { throw fail("a pattern lasts at most 8000 ms") }
        }
        if lastPause { throw fail("a pattern ends with a pulse") }
        return Pattern(pulses: pulses)
    }
}
extension GestureProfileSet {
    public var buzzNames: [String] { ProfileFormat.builtinBuzzes.map(\.name) + buzzes.keys.filter { name in !ProfileFormat.builtinBuzzes.contains { $0.name == name } }.sorted() }
    public func patternText(_ name: String) -> String { buzzes[name] ?? ProfileFormat.builtinBuzzes.first { $0.name == name }?.text ?? "" }
}
