import Foundation

/// The band's own handwriting model output, decoded the way Meta AI does (band-core `handwriting.rs`,
/// MIT): per frame the best of 100 symbols, the CTC blank's score lowered by ln 0.2 first; repeats
/// merge, blanks split them. The symbol order is Meta AI's `phones.txt`.
public enum Handwriting {
    public static let symbols = 100
    public static let blank = 99
    /// Sent when the writing pauses (between letters; longer pauses, likelier). Kept as a pause, not text.
    public static let pause = 87
    static let blankBias: Float = -1.609_438
    static let zero = 52
    static let space = 96
    static let underscore = 88

    private static let simple = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~")

    /// What each score index stands for; the blank is last.
    public static func symbol(_ index: Int) -> String {
        switch index {
        case 0...93: String(simple[index])
        case 94: "⌫"
        case 95: "⏎"
        case 96: "▁"
        case 97: "↑"
        case 98: "🤏"
        default: "·"
        }
    }

    /// A letter and its capital, o/O/0, and the two spaces count as one written thing.
    public static func group(_ index: Int) -> Int {
        switch index {
        case 26...51: index - 26
        case zero: 14
        case underscore: space
        default: index
        }
    }

    /// The frame's best symbol and its margin over the runner-up.
    public static func best(_ frame: [Float]) -> (index: Int, margin: Float) {
        var first = (blank, -Float.infinity)
        var second = -Float.infinity
        for (index, raw) in frame.prefix(symbols).enumerated() {
            let score = index == blank ? raw + blankBias : raw
            if score > first.1 {
                second = first.1
                first = (index, score)
            } else if score > second {
                second = score
            }
        }
        return (first.0, first.1 - second)
    }

    /// The top `count` symbols of a frame with their probabilities (softmax of the log-probs).
    public static func top(_ frame: [Float], count: Int = 5) -> [(index: Int, probability: Double)] {
        frame.prefix(symbols).enumerated()
            .map { ($0.offset, exp(Double($0.element))) }
            .sorted { $0.1 > $1.1 }
            .prefix(count)
            .map { (index: $0.0, probability: $0.1) }
    }
}

/// Greedy CTC over a stream of frames.
public struct HandwritingDecoder: Sendable {
    public private(set) var text = ""
    public private(set) var frames = 0
    /// Symbols as they arrived: index and margin in their first frame.
    public private(set) var tokens: [(index: Int, margin: Float)] = []
    private var last: Int?

    public init() {}

    /// One frame of scores; returns the symbol it added, if any.
    @discardableResult
    public mutating func push(_ frame: [Float]) -> (index: Int, margin: Float)? {
        frames += 1
        let (index, margin) = Handwriting.best(frame)
        defer { last = index }
        guard index != Handwriting.blank, last != index else { return nil }
        tokens.append((index, margin))
        if tokens.count > 400 { tokens.removeFirst(100) }
        if index != Handwriting.pause {
            switch index {
            case 94: if !text.isEmpty { text.removeLast() }  // backspace
            case 95: text += "\n"
            case 96, Handwriting.underscore: text += " "
            default: text += Handwriting.symbol(index)
            }
        }
        return (index, margin)
    }

    public mutating func clear() {
        text = ""
        tokens = []
        last = nil
    }
}
