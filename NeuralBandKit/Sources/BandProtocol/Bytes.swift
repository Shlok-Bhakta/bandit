import Foundation

/// Errors from the protocol core. Messages never contain key material or decrypted payloads.
public enum BandError: Error, LocalizedError, Sendable, Equatable {
    /// A malformed or unexpected message. Terminal for the session.
    case protocolError(String)
    /// The request can't run yet (another request is outstanding, or the session isn't ready).
    case busy(String)
    /// The band refused the ownership ceremony with a result code (`0x1042`: another account).
    case ownershipRejected(code: UInt32, message: String)
    /// The band refused the stored owner key (`0x1043`: enrolled to a different key).
    case identityMismatch(code: UInt32, message: String)

    public var errorDescription: String? {
        switch self {
        case .protocolError(let message), .busy(let message): message
        case .ownershipRejected(_, let message), .identityMismatch(_, let message): message
        }
    }

    public var code: UInt32? {
        switch self {
        case .ownershipRejected(let code, _), .identityMismatch(let code, _): code
        default: nil
        }
    }
}

@inline(__always) func perr(_ message: String) -> BandError { .protocolError(message) }

enum Bytes {
    static func be16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
    }

    static func be32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16
            | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
    }

    static func be(_ value: UInt16) -> [UInt8] { [UInt8(value >> 8), UInt8(value & 0xff)] }
    static func be(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24), UInt8((value >> 16) & 0xff), UInt8((value >> 8) & 0xff), UInt8(value & 0xff)]
    }
    static func le(_ value: UInt32) -> [UInt8] {
        [UInt8(value & 0xff), UInt8((value >> 8) & 0xff), UInt8((value >> 16) & 0xff), UInt8(value >> 24)]
    }

    static func random(_ count: Int) -> [UInt8] {
        var generator = SystemRandomNumberGenerator()
        return (0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
    }
}

extension Array where Element == UInt8 {
    /// Hex for diagnostics of *non-secret* values only (headers, type words).
    public var hex: String { map { String(format: "%02x", $0) }.joined() }

    public init?(hex: String) {
        let characters = Array(hex.utf8)
        guard characters.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(characters.count / 2)
        var index = 0
        while index < characters.count {
            guard let byte = UInt8(String(decoding: characters[index..<index + 2], as: UTF8.self), radix: 16) else {
                return nil
            }
            bytes.append(byte)
            index += 2
        }
        self = bytes
    }
}

extension UInt32 {
    public var hex8: String { String(format: "%08x", self) }
}
