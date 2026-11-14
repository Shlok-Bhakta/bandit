import Compression
import Foundation

/// A minimal ZIP reader for firmware packages: the central directory, stored and deflated entries,
/// CRC-checked. No ZIP64, no encryption (the packages need neither).
public struct ZipReader: Sendable {
    public struct Entry: Sendable, Equatable {
        public let name: String
        public let method: UInt16
        public let crc: UInt32
        public let compressedSize: Int
        public let size: Int
        let localOffset: Int

        public var methodName: String { method == 0 ? "stored" : method == 8 ? "deflate" : "method \(method)" }
    }

    public struct ZipError: LocalizedError {
        public let message: String
        init(_ message: String) { self.message = message }
        public var errorDescription: String? { message }
    }

    public let entries: [Entry]
    private let data: Data

    public init(data: Data) throws {
        self.data = data
        let bytes = [UInt8](data)
        func u16(_ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 }
        func u32(_ at: Int) -> Int { u16(at) | u16(at + 2) << 16 }
        guard bytes.count >= 22 else { throw ZipError("not a ZIP file (too short)") }
        var end = -1
        var index = bytes.count - 22
        while index >= max(0, bytes.count - 65_557) {
            if u32(index) == 0x0605_4b50 { end = index; break }
            index -= 1
        }
        guard end >= 0 else { throw ZipError("not a ZIP file (no end record)") }
        let count = u16(end + 10)
        var offset = u32(end + 16)
        guard u32(end + 12) != 0xffff_ffff, offset != 0xffff_ffff else { throw ZipError("ZIP64 isn't supported") }
        var entries: [Entry] = []
        for _ in 0..<count {
            guard offset + 46 <= bytes.count, u32(offset) == 0x0201_4b50 else { throw ZipError("damaged central directory") }
            let nameLength = u16(offset + 28)
            let extraLength = u16(offset + 30)
            let commentLength = u16(offset + 32)
            guard offset + 46 + nameLength <= bytes.count else { throw ZipError("damaged central directory") }
            let name = String(decoding: bytes[(offset + 46)..<(offset + 46 + nameLength)], as: UTF8.self)
            entries.append(Entry(name: name, method: UInt16(u16(offset + 10)), crc: UInt32(u32(offset + 16)),
                                 compressedSize: u32(offset + 20), size: u32(offset + 24), localOffset: u32(offset + 42)))
            offset += 46 + nameLength + extraLength + commentLength
        }
        self.entries = entries
    }

    public func entry(_ name: String) -> Entry? { entries.first { $0.name == name } }

    /// An entry's contents, inflated and CRC-checked.
    public func read(_ entry: Entry) throws -> Data {
        let start = entry.localOffset
        guard start + 30 <= data.count else { throw ZipError("\(entry.name): bad local header") }
        let header = data.subdata(in: start..<(start + 30))
        guard header[header.startIndex] == 0x50, header[header.startIndex + 1] == 0x4b,
              header[header.startIndex + 2] == 0x03, header[header.startIndex + 3] == 0x04 else { throw ZipError("\(entry.name): bad local header") }
        let nameLength = Int(header[header.startIndex + 26]) | Int(header[header.startIndex + 27]) << 8
        let extraLength = Int(header[header.startIndex + 28]) | Int(header[header.startIndex + 29]) << 8
        let body = start + 30 + nameLength + extraLength
        guard body + entry.compressedSize <= data.count else { throw ZipError("\(entry.name): truncated") }
        let compressed = data.subdata(in: body..<(body + entry.compressedSize))
        let output: Data
        switch entry.method {
        case 0:
            output = compressed
        case 8:
            guard entry.size > 0 else { output = Data(); break }
            var buffer = Data(count: entry.size)
            let written = buffer.withUnsafeMutableBytes { destination in
                compressed.withUnsafeBytes { source in
                    compression_decode_buffer(destination.bindMemory(to: UInt8.self).baseAddress!, entry.size,
                                              source.bindMemory(to: UInt8.self).baseAddress!, compressed.count, nil, COMPRESSION_ZLIB)
                }
            }
            guard written == entry.size else { throw ZipError("\(entry.name): couldn't inflate (\(written) of \(entry.size) bytes)") }
            output = buffer
        default:
            throw ZipError("\(entry.name): unsupported compression \(entry.method)")
        }
        guard Self.crc32(output) == entry.crc else { throw ZipError("\(entry.name): CRC mismatch") }
        return output
    }

    private static let table: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 { crc = crc & 1 == 1 ? 0xedb8_8320 ^ (crc >> 1) : crc >> 1 }
        return crc
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for byte in data { crc = table[Int((crc ^ UInt32(byte)) & 0xff)] ^ (crc >> 8) }
        return crc ^ 0xffff_ffff
    }
}
