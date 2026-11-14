import Foundation

/// Minimal protobuf reader, ported from band-core `proto.rs`.
/// Field values may be plaintext sensor data or key material: never log them.
public struct ProtoFields: Sendable {
    enum Value: Sendable {
        case integer(UInt64)
        case bytes([UInt8])
        case fixed([UInt8])
    }

    private(set) var values: [UInt32: [Value]] = [:]

    public init(parsing data: [UInt8]) throws {
        var offset = 0
        func varint() throws -> UInt64 {
            var value: UInt64 = 0
            var shift: UInt64 = 0
            while shift <= 63 {
                guard offset < data.count else { throw perr("Truncated protobuf varint") }
                let byte = data[offset]
                offset += 1
                if shift == 63 && byte > 1 { throw perr("Protobuf varint overflow") }
                value |= UInt64(byte & 127) << shift
                if byte < 128 { return value }
                shift += 7
            }
            throw perr("Unterminated protobuf varint")
        }
        while offset < data.count {
            let tag = try varint()
            let number = tag >> 3
            guard number != 0, number < 1 << 29 else { throw perr("Invalid protobuf field number") }
            let field = UInt32(number)
            let wire = tag & 7
            if wire == 0 {
                values[field, default: []].append(.integer(try varint()))
                continue
            }
            let size: UInt64
            switch wire {
            case 1: size = 8
            case 2: size = try varint()
            case 5: size = 4
            default: throw perr("Unsupported protobuf wire type")
            }
            guard size <= UInt64(data.count - offset) else { throw perr("Truncated protobuf field") }
            let slice = Array(data[offset..<offset + Int(size)])
            values[field, default: []].append(wire == 2 ? .bytes(slice) : .fixed(slice))
            offset += Int(size)
        }
    }

    /// The single integer in `field`, or 0 when absent (band-core semantics).
    public func integer(_ field: UInt32) throws -> UInt64 {
        guard let list = values[field] else { return 0 }
        guard list.count == 1, case .integer(let value) = list[0] else { throw perr("Expected protobuf integer") }
        return value
    }

    public func requiredInteger(_ field: UInt32) throws -> UInt64 {
        guard values[field] != nil else { throw perr("Missing protobuf integer") }
        return try integer(field)
    }

    public func bytes(_ field: UInt32) throws -> [UInt8] {
        guard let list = values[field], list.count == 1, case .bytes(let bytes) = list[0] else {
            throw perr("Invalid protobuf byte field")
        }
        return bytes
    }

    public func bytes(_ field: UInt32, count: Int) throws -> [UInt8] {
        let value = try bytes(field)
        guard value.count == count else { throw perr("Invalid protobuf byte field") }
        return value
    }

    public func contains(_ field: UInt32) -> Bool { values[field] != nil }

    /// Every length-delimited value with its field number, sorted by field.
    public func byteFields() -> [(UInt32, [UInt8])] {
        values.flatMap { field, list in
            list.compactMap { value -> (UInt32, [UInt8])? in
                if case .bytes(let bytes) = value { return (field, bytes) }
                return nil
            }
        }.sorted { $0.0 < $1.0 }
    }

    /// A UTF-8 string field, or nil when absent, repeated or not text.
    public func text(_ field: UInt32) -> String? {
        guard let bytes = try? bytes(field) else { return nil }
        return String(bytes: bytes, encoding: .utf8)
    }

    /// A structural summary for diagnostics: field numbers, integer values (small ones only), byte
    /// lengths, and nested messages up to `depth`. Byte contents are never shown, so certificates,
    /// signatures and keys stay out of logs. Example: `1=3 2=[64B] 3={1=1 2=[16B]}`.
    public func shape(depth: Int = 2) -> String {
        var parts: [String] = []
        for field in values.keys.sorted() {
            for value in values[field] ?? [] {
                switch value {
                case .integer(let integer):
                    parts.append(integer < 1 << 32 ? "\(field)=\(integer)" : "\(field)=<large int>")
                case .fixed(let bytes):
                    parts.append("\(field)=<fixed\(bytes.count * 8)>")
                case .bytes(let bytes):
                    if depth > 0, bytes.count >= 2, bytes.count <= 512, let inner = try? ProtoFields(parsing: bytes), !inner.values.isEmpty,
                       inner.values.values.allSatisfy({ $0.allSatisfy { if case .fixed = $0 { false } else { true } } }) {
                        parts.append("\(field)={\(inner.shape(depth: depth - 1))}")
                    } else {
                        parts.append("\(field)=[\(bytes.count)B]")
                    }
                }
            }
        }
        return parts.joined(separator: " ")
    }

    /// The field numbers present (never values), for diagnostics.
    public var fieldNumbers: [UInt32] { values.keys.sorted() }

    /// A readable dump WITH values: integers, printable strings, nested messages, short byte prefixes.
    /// Only for messages known to carry no secrets (settings, config, update status), never for
    /// identity, trust or sensor payloads.
    public func readable(depth: Int = 3, skipping: Set<UInt32> = []) -> String {
        var parts: [String] = []
        for field in values.keys.sorted() where !skipping.contains(field) {
            for value in values[field] ?? [] {
                switch value {
                case .integer(let integer):
                    parts.append("\(field)=\(integer)")
                case .fixed(let bytes):
                    if bytes.count == 4 {
                        let bits = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
                        parts.append("\(field)=\(Float(bitPattern: bits))f")
                    } else {
                        parts.append("\(field)=0x\(bytes.reversed().map { String(format: "%02x", $0) }.joined())")
                    }
                case .bytes(let bytes):
                    if bytes.isEmpty {
                        parts.append("\(field)={}")
                    } else if let text = Self.printable(bytes) {
                        parts.append("\(field)=\"\(text)\"")
                    } else if depth > 0, let inner = try? ProtoFields(parsing: bytes), !inner.values.isEmpty {
                        parts.append("\(field)={\(inner.readable(depth: depth - 1))}")
                    } else {
                        let hex = bytes.prefix(16).map { String(format: "%02x", $0) }.joined()
                        parts.append("\(field)=[\(bytes.count)B \(hex)\(bytes.count > 16 ? "…" : "")]")
                    }
                }
            }
        }
        return parts.joined(separator: " ")
    }

    static func printable(_ bytes: [UInt8]) -> String? {
        guard bytes.count >= 2, let text = String(bytes: bytes, encoding: .utf8),
              text.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7f }) else { return nil }
        return text
    }

    /// The single integer in `field` if it holds one, without throwing.
    public func optionalInteger(_ field: UInt32) -> UInt64? {
        guard let list = values[field], list.count == 1, case .integer(let value) = list[0] else { return nil }
        return value
    }
}

/// Protobuf writer helpers.
public enum Proto {
    public static func varint(_ value: UInt64) -> [UInt8] {
        var value = value
        var bytes: [UInt8] = []
        while value >= 128 {
            bytes.append(UInt8(value & 127) | 128)
            value >>= 7
        }
        bytes.append(UInt8(value))
        return bytes
    }

    public static func field(_ number: UInt32, _ value: UInt64) -> [UInt8] {
        varint(UInt64(number) << 3) + varint(value)
    }

    public static func field(_ number: UInt32, bytes: [UInt8]) -> [UInt8] {
        varint(UInt64(number) << 3 | 2) + varint(UInt64(bytes.count)) + bytes
    }
}
