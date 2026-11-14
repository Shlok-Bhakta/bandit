import Foundation

/// One DataX frame inside decrypted AirShield records: `u16be size | u16be channel | [u32be words…] | payload`.
/// The size's top bit says typed words follow; each word with its top bit set is followed by another.
/// Ported from band-core `datax.rs`. Payloads are plaintext: never log them.
public struct DataXFrame: Sendable, Equatable {
    public var channel: UInt16
    public var words: [UInt32]
    public var payload: [UInt8]

    public init(channel: UInt16, words: [UInt32], payload: [UInt8]) {
        self.channel = channel
        self.words = words
        self.payload = payload
    }

    /// Channel/type/size only, safe to log.
    public var summary: String {
        "ch 0x\(String(channel, radix: 16)) words [\(words.map(\.hex8).joined(separator: ","))] \(payload.count)B"
    }
}

public enum DataX {
    public static func encode(channel: UInt16, words: [UInt32] = [], payload: [UInt8] = []) throws -> [UInt8] {
        var body: [UInt8] = []
        body.reserveCapacity(words.count * 4 + payload.count)
        for word in words { body += Bytes.be(word) }
        body += payload
        guard body.count <= 0x7fff else { throw perr("DataX frame too large") }
        let size = UInt16(body.count) | (words.isEmpty ? 0 : 0x8000)
        return Bytes.be(size) + Bytes.be(channel) + body
    }
}

/// A record without its trailing `n` bytes of `0xc0 + n` (1...16), or whole when it has none.
private func withoutPadding(_ record: [UInt8]) -> ArraySlice<UInt8> {
    guard let marker = record.last else { return record[...] }
    let count = Int(marker &- 0xc0)
    if (1...16).contains(count), count <= record.count,
       record[(record.count - count)...].allSatisfy({ $0 == marker }) {
        return record[..<(record.count - count)]
    }
    return record[...]
}

/// Reassembles frames that span several decrypted 16-byte-aligned records.
public struct DataXReceiver: Sendable {
    private var pending: [UInt8] = []
    /// The sender pads every record (all schemes but 3), so each record's padding comes off exactly.
    private(set) var alwaysPadded = false

    public init() {}

    public mutating func setAlwaysPadded() { alwaysPadded = true }
    public var pendingCount: Int { pending.count }

    public mutating func feed(_ plaintext: [UInt8]) throws -> [DataXFrame] {
        guard !plaintext.isEmpty, plaintext.count.isMultiple(of: 16) else { throw perr("Unaligned DataX plaintext") }
        if !alwaysPadded, plaintext.suffix(16) == ArraySlice(repeating: 0xd0, count: 16) {
            alwaysPadded = true
        }
        if alwaysPadded { pending += withoutPadding(plaintext) } else { pending += plaintext }
        var frames: [DataXFrame] = []
        var consumed = 0
        while pending.count - consumed >= 4 {
            let length = Bytes.be16(pending, consumed)
            let size = Int(length & 0x7fff) + 4
            guard pending.count - consumed >= size else { break }
            let channel = Bytes.be16(pending, consumed + 2)
            var offset = 4
            var words: [UInt32] = []
            if length & 0x8000 != 0 {
                while true {
                    guard offset + 4 <= size else {
                        pending.removeFirst(consumed)
                        throw perr("Truncated DataX typed header")
                    }
                    let word = Bytes.be32(pending, consumed + offset)
                    words.append(word)
                    offset += 4
                    if word & 0x8000_0000 == 0 { break }
                }
            }
            frames.append(DataXFrame(channel: channel, words: words,
                                     payload: Array(pending[(consumed + offset)..<(consumed + size)])))
            consumed += size
        }
        if consumed > 0 { pending.removeFirst(consumed) }
        if !alwaysPadded { stripPadding() }
        return frames
    }

    /// Only a repeated suffix after the last complete frame is stripped (scheme-3 rule).
    private mutating func stripPadding() {
        guard let marker = pending.last else { return }
        let count = Int(marker &- 0xc0)
        guard (1...16).contains(count), count <= pending.count else { return }
        let tail = pending.count - count
        if pending[tail...].allSatisfy({ $0 == marker }) { pending.removeLast(count) }
    }
}
