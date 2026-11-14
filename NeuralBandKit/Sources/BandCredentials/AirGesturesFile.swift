import BandProtocol
import Foundation

/// The band as air-gestures records it (`air-gesturesd/src/store.rs` `BandRecord`).
/// `address` is the band's Bluetooth identity address (`AA:BB:CC:DD:EE:FF`), which iOS never
/// exposes: it comes from an imported file or is typed in from `bluetoothctl devices` on Linux.
public struct AirGesturesBand: Codable, Equatable, Sendable {
    public var address: String
    public var name: String
    /// Which `SCHEME_26_GUESSES` entry a newer-firmware band answered to.
    public var schemeGuess: Int?

    public init(address: String, name: String, schemeGuess: Int?) {
        self.address = address
        self.name = name
        self.schemeGuess = schemeGuess
    }

    enum CodingKeys: String, CodingKey {
        case address, name
        case schemeGuess = "scheme_guess"
    }

    public static func isValidAddress(_ text: String) -> Bool {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        return parts.count == 6 && parts.allSatisfy { $0.count == 2 && UInt8($0, radix: 16) != nil }
    }

    /// A resolvable private address: random, with the top two bits of the first octet `01`.
    public static func isPrivateAddress(_ text: String) -> Bool {
        guard let first = UInt8(text.prefix(2), radix: 16) else { return false }
        return first >> 6 == 0b01
    }
}

/// `air-gestures-band.json`: the owner key (base64) and band record in one file that air-gestures
/// (Linux), its Android app and rokid-lumen all write and read. Mirrors `air-gestures/src/transfer.rs`.
///
/// ```json
/// { "format": "air-gestures-band", "version": 1, "owner_key": "<base64 32|97 bytes>",
///   "band": { "address": "AA:BB:CC:DD:EE:FF", "name": "Meta Band 1234", "scheme_guess": 0 } }
/// ```
/// `band` is optional; within it, `address` and `name` are required and `scheme_guess` optional.
public enum AirGesturesFile {
    public static let format = "air-gestures-band"
    public static let version = 1
    public static let defaultFileName = "air-gestures-band.json"

    public struct Imported: Sendable {
        public let identity: OwnerIdentity
        public let band: AirGesturesBand?
        /// True when the file was a bare `owner.key` rather than the JSON bundle.
        public let rawKey: Bool
    }

    public enum ParseError: LocalizedError, Equatable {
        case notABandFile(String)
        case newerVersion(Int)
        case malformed(String)

        public var errorDescription: String? {
            switch self {
            case .notABandFile(let reason): "Not an air-gestures band file (\(reason))."
            case .newerVersion(let version): "This band file is version \(version), newer than this app understands (\(AirGesturesFile.version))."
            case .malformed(let reason): "This band file is malformed: \(reason)."
            }
        }
    }

    /// The exact bytes air-gestures writes (`serde_json::to_vec_pretty` + newline). Contains the secret.
    public static func encode(identity: OwnerIdentity, band: AirGesturesBand?) -> Data {
        func quoted(_ text: String) -> String {
            let data = try? JSONSerialization.data(withJSONObject: [text], options: [.withoutEscapingSlashes])
            let array = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
            return String(array.dropFirst().dropLast())
        }
        var lines = [
            "{",
            "  \"format\": \(quoted(format)),",
            "  \"version\": \(version),",
            "  \"owner_key\": \(quoted(Data(identity.ownerKeyBytes).base64EncodedString()))\(band == nil ? "" : ",")",
        ]
        if let band {
            lines.append("  \"band\": {")
            lines.append("    \"address\": \(quoted(band.address)),")
            lines.append("    \"name\": \(quoted(band.name))\(band.schemeGuess == nil ? "" : ",")")
            if let guess = band.schemeGuess { lines.append("    \"scheme_guess\": \(guess)") }
            lines.append("  }")
        }
        lines.append("}")
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    /// Reads the bundle, or (for convenience) a raw 32- or 97-byte `owner.key`.
    public static func parse(_ data: Data) throws -> Imported {
        let object = try? JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any] else {
            if data.count == 32 || data.count == 97 {
                do {
                    return Imported(identity: try OwnerIdentity(ownerKeyBytes: [UInt8](data)), band: nil, rawKey: true)
                } catch {
                    throw ParseError.malformed("that isn't a usable owner key: \(error.localizedDescription)")
                }
            }
            throw ParseError.notABandFile("expected \(defaultFileName) or an owner.key")
        }
        guard dictionary["format"] as? String == format else {
            throw ParseError.notABandFile("its \"format\" isn't \"\(format)\"")
        }
        guard let number = dictionary["version"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
            throw ParseError.malformed("it has no usable \"version\"")
        }
        let fileVersion = number.intValue
        if fileVersion > version { throw ParseError.newerVersion(fileVersion) }
        guard fileVersion == version else { throw ParseError.malformed("it has no usable \"version\"") }
        guard let encoded = dictionary["owner_key"] as? String else { throw ParseError.malformed("missing \"owner_key\"") }
        guard let key = Data(base64Encoded: encoded.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw ParseError.malformed("the owner key isn't valid base64")
        }
        let identity: OwnerIdentity
        do { identity = try OwnerIdentity(ownerKeyBytes: [UInt8](key)) } catch {
            throw ParseError.malformed("the owner key isn't usable: \(error.localizedDescription)")
        }
        var band: AirGesturesBand?
        if let raw = dictionary["band"], !(raw is NSNull) {
            guard let record = raw as? [String: Any], let address = record["address"] as? String,
                  let name = record["name"] as? String else {
                throw ParseError.malformed("\"band\" needs a string \"address\" and \"name\"")
            }
            var guess: Int?
            if let value = record["scheme_guess"], !(value is NSNull) {
                guard let number = value as? NSNumber, number.intValue >= 0 else {
                    throw ParseError.malformed("\"scheme_guess\" isn't a non-negative integer")
                }
                guess = number.intValue
            }
            band = AirGesturesBand(address: address, name: name, schemeGuess: guess)
        }
        return Imported(identity: identity, band: band, rawKey: false)
    }
}
