import Foundation

/// A JSON document as written, for profile files: object members keep their order (and any
/// duplicates), integers stay integers, so the app can keep fields it doesn't know and write a
/// file back byte for byte the way it decided to. Strict RFC 8259 parsing, like serde_json.
public enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case integer(Int64)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object(JSONObject)

    public var string: String? { if case .string(let value) = self { value } else { nil } }
    public var object: JSONObject? { if case .object(let value) = self { value } else { nil } }
    public var array: [JSONValue]? { if case .array(let value) = self { value } else { nil } }
    public var bool: Bool? { if case .bool(let value) = self { value } else { nil } }
    public var integer: Int64? { if case .integer(let value) = self { value } else { nil } }

    var isScalar: Bool {
        switch self {
        case .array, .object: false
        default: true
        }
    }

    /// What serde calls it in "invalid type" messages.
    var typeName: String {
        switch self {
        case .null: "null"
        case .bool: "a boolean"
        case .integer: "an integer"
        case .number: "a number"
        case .string: "a string"
        case .array: "an array"
        case .object: "an object"
        }
    }
}

/// Object members in file order.
public struct JSONObject: Equatable, Sendable {
    public struct Member: Equatable, Sendable {
        public var key: String
        public var value: JSONValue

        public init(_ key: String, _ value: JSONValue) {
            self.key = key
            self.value = value
        }
    }

    public var members: [Member]

    public init(_ members: [Member] = []) { self.members = members }

    /// The last member with this key (what a map reader keeps).
    public subscript(key: String) -> JSONValue? { members.last(where: { $0.key == key })?.value }

    /// Keys once each, sorted by UTF-8 bytes, with the last value of each: how Rust's `BTreeMap`
    /// (and serde_json's default `Map`) reads an object.
    public var sortedUnique: [Member] {
        var last: [String: JSONValue] = [:]
        for member in members { last[member.key] = member.value }
        return last.keys.sorted(by: JSONObject.byteOrder).map { Member($0, last[$0]!) }
    }

    static func byteOrder(_ a: String, _ b: String) -> Bool { a.utf8.lexicographicallyPrecedes(b.utf8) }

    public mutating func append(_ key: String, _ value: JSONValue) { members.append(Member(key, value)) }
}

public struct JSONParseError: Error, Equatable, Sendable, CustomStringConvertible {
    public let message: String
    /// Byte offset of the problem.
    public let offset: Int

    public var description: String { "\(message) at byte \(offset)" }
}

// MARK: parsing

extension JSONValue {
    public static func parse(_ data: Data) throws -> JSONValue {
        guard String(data: data, encoding: .utf8) != nil else { throw JSONParseError(message: "not UTF-8 text", offset: 0) }
        var parser = JSONParser(bytes: [UInt8](data))
        return try parser.document()
    }

    public static func parse(_ text: String) throws -> JSONValue { try parse(Data(text.utf8)) }
}

private struct JSONParser {
    static let maxDepth = 128

    let bytes: [UInt8]
    var index = 0
    var depth = 0

    init(bytes: [UInt8]) { self.bytes = bytes }

    func fail(_ message: String) -> JSONParseError { JSONParseError(message: message, offset: index) }

    mutating func document() throws -> JSONValue {
        skipSpace()
        let value = try parseValue()
        skipSpace()
        guard index == bytes.count else { throw fail("trailing characters") }
        return value
    }

    mutating func skipSpace() {
        while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
    }

    mutating func parseValue() throws -> JSONValue {
        guard index < bytes.count else { throw fail("unexpected end of the file") }
        switch bytes[index] {
        case UInt8(ascii: "{"): return try parseObject()
        case UInt8(ascii: "["): return try parseArray()
        case UInt8(ascii: "\""): return .string(try parseString())
        case UInt8(ascii: "t"): try literal("true"); return .bool(true)
        case UInt8(ascii: "f"): try literal("false"); return .bool(false)
        case UInt8(ascii: "n"): try literal("null"); return .null
        case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return try parseNumber()
        default: throw fail("expected a value")
        }
    }

    mutating func literal(_ word: String) throws {
        let expected = Array(word.utf8)
        guard bytes.count - index >= expected.count, Array(bytes[index..<index + expected.count]) == expected else { throw fail("expected \(word)") }
        index += expected.count
    }

    mutating func nest() throws {
        depth += 1
        if depth > Self.maxDepth { throw fail("nested too deeply") }
    }

    mutating func parseObject() throws -> JSONValue {
        try nest()
        defer { depth -= 1 }
        index += 1
        var object = JSONObject()
        skipSpace()
        if index < bytes.count, bytes[index] == UInt8(ascii: "}") { index += 1; return .object(object) }
        while true {
            skipSpace()
            guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw fail("expected a key") }
            let key = try parseString()
            skipSpace()
            guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { throw fail("expected :") }
            index += 1
            skipSpace()
            object.append(key, try parseValue())
            skipSpace()
            guard index < bytes.count else { throw fail("unexpected end of the file") }
            if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
            if bytes[index] == UInt8(ascii: "}") { index += 1; return .object(object) }
            throw fail("expected , or }")
        }
    }

    mutating func parseArray() throws -> JSONValue {
        try nest()
        defer { depth -= 1 }
        index += 1
        var items: [JSONValue] = []
        skipSpace()
        if index < bytes.count, bytes[index] == UInt8(ascii: "]") { index += 1; return .array(items) }
        while true {
            skipSpace()
            items.append(try parseValue())
            skipSpace()
            guard index < bytes.count else { throw fail("unexpected end of the file") }
            if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
            if bytes[index] == UInt8(ascii: "]") { index += 1; return .array(items) }
            throw fail("expected , or ]")
        }
    }

    mutating func parseString() throws -> String {
        index += 1
        var out: [UInt8] = []
        while true {
            guard index < bytes.count else { throw fail("unterminated string") }
            let byte = bytes[index]
            switch byte {
            case UInt8(ascii: "\""):
                index += 1
                return String(decoding: out, as: UTF8.self)
            case UInt8(ascii: "\\"):
                index += 1
                guard index < bytes.count else { throw fail("unterminated string") }
                let escape = bytes[index]
                index += 1
                switch escape {
                case UInt8(ascii: "\""): out.append(0x22)
                case UInt8(ascii: "\\"): out.append(0x5C)
                case UInt8(ascii: "/"): out.append(0x2F)
                case UInt8(ascii: "b"): out.append(0x08)
                case UInt8(ascii: "f"): out.append(0x0C)
                case UInt8(ascii: "n"): out.append(0x0A)
                case UInt8(ascii: "r"): out.append(0x0D)
                case UInt8(ascii: "t"): out.append(0x09)
                case UInt8(ascii: "u"):
                    var code = try hex4()
                    if (0xD800...0xDBFF).contains(code) {
                        guard bytes.count - index >= 6, bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u") else {
                            throw fail("lone surrogate in \\u escape")
                        }
                        index += 2
                        let low = try hex4()
                        guard (0xDC00...0xDFFF).contains(low) else { throw fail("invalid surrogate pair") }
                        code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                    } else if (0xDC00...0xDFFF).contains(code) {
                        throw fail("lone surrogate in \\u escape")
                    }
                    guard let scalar = Unicode.Scalar(code) else { throw fail("invalid \\u escape") }
                    out.append(contentsOf: Array(String(Character(scalar)).utf8))
                default:
                    throw fail("invalid escape")
                }
            case 0x00..<0x20:
                throw fail("control character in a string")
            default:
                out.append(byte)
                index += 1
            }
        }
    }

    mutating func hex4() throws -> UInt32 {
        guard bytes.count - index >= 4 else { throw fail("short \\u escape") }
        var value: UInt32 = 0
        for _ in 0..<4 {
            let byte = bytes[index]
            let digit: UInt32
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = UInt32(byte - UInt8(ascii: "0"))
            case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = UInt32(byte - UInt8(ascii: "a") + 10)
            case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = UInt32(byte - UInt8(ascii: "A") + 10)
            default: throw fail("invalid \\u escape")
            }
            value = value << 4 | digit
            index += 1
        }
        return value
    }

    mutating func parseNumber() throws -> JSONValue {
        let start = index
        var integral = true
        if bytes[index] == UInt8(ascii: "-") { index += 1 }
        guard index < bytes.count, isDigit(bytes[index]) else { throw fail("invalid number") }
        if bytes[index] == UInt8(ascii: "0") {
            index += 1
        } else {
            while index < bytes.count, isDigit(bytes[index]) { index += 1 }
        }
        if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
            integral = false
            index += 1
            guard index < bytes.count, isDigit(bytes[index]) else { throw fail("invalid number") }
            while index < bytes.count, isDigit(bytes[index]) { index += 1 }
        }
        if index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
            integral = false
            index += 1
            if index < bytes.count, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") { index += 1 }
            guard index < bytes.count, isDigit(bytes[index]) else { throw fail("invalid number") }
            while index < bytes.count, isDigit(bytes[index]) { index += 1 }
        }
        let text = String(decoding: bytes[start..<index], as: UTF8.self)
        if integral, let value = Int64(text) { return .integer(value) }
        guard let value = Double(text), value.isFinite else { throw fail("number out of range") }
        return .number(value)
    }

    func isDigit(_ byte: UInt8) -> Bool { (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) }
}

// MARK: writing

extension JSONValue {
    /// No whitespace at all: what the dongle stores and hashes.
    public var minified: String {
        var out = ""
        write(to: &out, indent: nil, level: 0)
        return out
    }

    /// Two-space indentation for people (and AI assistants). Short objects and arrays of plain
    /// values stay on one line, like the hand-written files in firmware/np-profiles.
    public var pretty: String {
        var out = ""
        write(to: &out, indent: "  ", level: 0)
        return out + "\n"
    }

    static let inlineWidth = 88

    private func write(to out: inout String, indent: String?, level: Int) {
        switch self {
        case .null: out += "null"
        case .bool(let value): out += value ? "true" : "false"
        case .integer(let value): out += String(value)
        case .number(let value): out += value.rounded() == value && abs(value) < 1e15 ? String(format: "%.1f", value) : "\(value)"
        case .string(let value): Self.quote(value, into: &out)
        case .array(let items):
            guard let indent, !items.isEmpty, !fitsInline(level: level) else {
                out += "["
                for (i, item) in items.enumerated() {
                    if i > 0 { out += indent == nil ? "," : ", " }
                    item.write(to: &out, indent: indent == nil ? nil : "", level: level + 1)
                }
                out += "]"
                return
            }
            out += "[\n"
            for (i, item) in items.enumerated() {
                out += String(repeating: indent, count: level + 1)
                item.write(to: &out, indent: indent, level: level + 1)
                out += i < items.count - 1 ? ",\n" : "\n"
            }
            out += String(repeating: indent, count: level) + "]"
        case .object(let object):
            guard let indent, !object.members.isEmpty, !fitsInline(level: level) else {
                let spaced = indent != nil
                out += spaced && !object.members.isEmpty ? "{ " : "{"
                for (i, member) in object.members.enumerated() {
                    if i > 0 { out += spaced ? ", " : "," }
                    Self.quote(member.key, into: &out)
                    out += spaced ? ": " : ":"
                    member.value.write(to: &out, indent: spaced ? "" : nil, level: level + 1)
                }
                out += spaced && !object.members.isEmpty ? " }" : "}"
                return
            }
            out += "{\n"
            for (i, member) in object.members.enumerated() {
                out += String(repeating: indent, count: level + 1)
                Self.quote(member.key, into: &out)
                out += ": "
                member.value.write(to: &out, indent: indent, level: level + 1)
                out += i < object.members.count - 1 ? ",\n" : "\n"
            }
            out += String(repeating: indent, count: level) + "}"
        }
    }

    /// Nested containers of plain values that fit on a line are written on one.
    private func fitsInline(level: Int) -> Bool {
        guard level > 0 else { return false }
        let children: [JSONValue]
        switch self {
        case .array(let items): children = items
        case .object(let object): children = object.members.map(\.value)
        default: return true
        }
        guard children.allSatisfy(\.isScalar) else { return false }
        var line = ""
        write(to: &line, indent: nil, level: level)
        return line.count + children.count * 2 + level * 2 <= Self.inlineWidth
    }

    static func quote(_ text: String, into out: inout String) {
        out += "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case let control where control.value < 0x20: out += String(format: "\\u%04x", control.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        out += "\""
    }
}
