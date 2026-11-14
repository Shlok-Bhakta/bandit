import BandProtocol
import CommonCrypto
import CryptoKit
import Foundation

/// A password-encrypted wrapper around an `air-gestures-band.json`, clearly distinct from the
/// plain air-gestures format (different `format`, different extension `.npbackup`).
///
/// ```json
/// { "format": "neural-playground-encrypted-backup", "version": 1,
///   "kdf": { "name": "PBKDF2-HMAC-SHA256", "iterations": 600000, "salt": "<b64 16B>" },
///   "cipher": { "name": "AES-256-GCM", "nonce": "<b64 12B>", "ciphertext": "<b64>", "tag": "<b64 16B>" },
///   "hint": { "band_name": "...", "owner_fingerprint": "XXXX-XXXX-XXXX-XXXX", "created": "ISO8601" } }
/// ```
/// The plaintext is the exact air-gestures JSON, so decrypting yields a file Linux/Android can import.
/// To decrypt elsewhere: PBKDF2-SHA256(password UTF-8, salt, iterations, 32 bytes) → AES-256-GCM with
/// the nonce, additional data = UTF-8 of `neural-playground-encrypted-backup/1`.
public enum EncryptedBackup {
    public static let format = "neural-playground-encrypted-backup"
    public static let version = 1
    public static let fileExtension = "npbackup"
    public static let minimumPasswordLength = 10
    public static let iterations: UInt32 = 600_000
    static var aad: Data { Data("\(format)/\(version)".utf8) }

    public enum BackupError: LocalizedError, Equatable {
        case passwordTooShort
        case notABackup
        case unsupported(String)
        case wrongPassword

        public var errorDescription: String? {
            switch self {
            case .passwordTooShort: "Use a password of at least \(EncryptedBackup.minimumPasswordLength) characters."
            case .notABackup: "This isn't a Neural Playground encrypted backup."
            case .unsupported(let reason): "This backup can't be read: \(reason)."
            case .wrongPassword: "Wrong password, or the backup was modified."
            }
        }
    }

    public struct Hint: Sendable, Equatable {
        public let bandName: String?
        public let ownerFingerprint: String?
        public let created: String?
    }

    static func deriveKey(password: String, salt: [UInt8], iterations: UInt32) throws -> SymmetricKey {
        var key = [UInt8](repeating: 0, count: 32)
        let passwordBytes = Array(password.utf8)
        let status = passwordBytes.withUnsafeBufferPointer { passwordPointer in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                 passwordPointer.baseAddress.map { UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self) },
                                 passwordBytes.count, salt, salt.count,
                                 CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), iterations, &key, key.count)
        }
        guard status == kCCSuccess else { throw BackupError.unsupported("key derivation failed") }
        return SymmetricKey(data: key)
    }

    public static func encrypt(airGesturesJSON plaintext: Data, password: String, bandName: String?,
                               fingerprint: String?, iterations: UInt32 = iterations) throws -> Data {
        guard password.count >= minimumPasswordLength else { throw BackupError.passwordTooShort }
        let salt = (0..<16).map { _ in UInt8.random(in: 0...255) }
        let key = try deriveKey(password: password, salt: salt, iterations: iterations)
        let sealed = try AES.GCM.seal(plaintext, using: key, authenticating: aad)
        var hint: [String: String] = ["created": ISO8601DateFormatter().string(from: Date())]
        hint["band_name"] = bandName
        hint["owner_fingerprint"] = fingerprint
        let object: [String: Any] = [
            "format": format,
            "version": version,
            "kdf": ["name": "PBKDF2-HMAC-SHA256", "iterations": Int(iterations), "salt": Data(salt).base64EncodedString()],
            "cipher": ["name": "AES-256-GCM",
                       "nonce": Data(sealed.nonce).base64EncodedString(),
                       "ciphertext": sealed.ciphertext.base64EncodedString(),
                       "tag": sealed.tag.base64EncodedString()],
            "hint": hint,
        ]
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }

    public static func isBackup(_ data: Data) -> Bool {
        ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["format"] as? String == format
    }

    public static func hint(_ data: Data) -> Hint? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              object["format"] as? String == format else { return nil }
        let hint = object["hint"] as? [String: Any]
        return Hint(bandName: hint?["band_name"] as? String, ownerFingerprint: hint?["owner_fingerprint"] as? String,
                    created: hint?["created"] as? String)
    }

    /// Returns the air-gestures JSON inside.
    public static func decrypt(_ data: Data, password: String) throws -> Data {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              object["format"] as? String == format else { throw BackupError.notABackup }
        guard (object["version"] as? Int) == version else { throw BackupError.unsupported("unknown version") }
        guard let kdf = object["kdf"] as? [String: Any], kdf["name"] as? String == "PBKDF2-HMAC-SHA256",
              let iterations = kdf["iterations"] as? Int, (100_000...10_000_000).contains(iterations),
              let salt = (kdf["salt"] as? String).flatMap({ Data(base64Encoded: $0) }), salt.count >= 16 else {
            throw BackupError.unsupported("unknown key derivation")
        }
        guard let cipher = object["cipher"] as? [String: Any], cipher["name"] as? String == "AES-256-GCM",
              let nonce = (cipher["nonce"] as? String).flatMap({ Data(base64Encoded: $0) }),
              let ciphertext = (cipher["ciphertext"] as? String).flatMap({ Data(base64Encoded: $0) }),
              let tag = (cipher["tag"] as? String).flatMap({ Data(base64Encoded: $0) }) else {
            throw BackupError.unsupported("unknown cipher")
        }
        let key = try deriveKey(password: password, salt: [UInt8](salt), iterations: UInt32(iterations))
        do {
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce), ciphertext: ciphertext, tag: tag)
            return try AES.GCM.open(box, using: key, authenticating: aad)
        } catch {
            throw BackupError.wrongPassword
        }
    }
}
