import CommonCrypto
import CryptoKit
import Foundation

/// AirShield transport encryption, ported from band-core `airshield.rs`.
///
/// Record: `0x40 | HMAC-SHA256(prefix || counter_le || body)[..8] | body`, where
/// `body = (blocks - 1) as u8 || AES-256-CBC(frame padded with 0xc0+n)`.
/// The IV chains from the previous ciphertext block and the counter wraps.
public enum MacKeySource: Sendable, Equatable {
    /// The encryption key itself (scheme 3).
    case encryption
    /// `HKDF(S, salt: SHA256(R || C || "hmac_derive"))` (scheme 31).
    case derived
    /// `HKDF(H, salt: SHA256(R || C || "hmac_derive" || H))`.
    case derivedHashed
}

/// One way of turning the ECDH secret into record keys.
public struct AirShieldVariant: Sendable, Equatable {
    /// HKDF input `H = SHA256(S)` with salt `SHA256(H || C || R)` (scheme 3), else `S` with salt `SHA256(C || R)`.
    public var hashedSecret: Bool
    public var macKey: MacKeySource
    /// The MAC covers `02 02 00 00` first (scheme 31).
    public var macPrefix: Bool
    /// The scheme number our EnableEncryption names.
    public var announce: UInt64

    public static let scheme3 = AirShieldVariant(hashedSecret: true, macKey: .encryption, macPrefix: false, announce: 3)
    public static let scheme31 = AirShieldVariant(hashedSecret: false, macKey: .derived, macPrefix: true, announce: 31)

    private static func guess(_ hashed: Bool, _ mac: MacKeySource, _ prefix: Bool) -> AirShieldVariant {
        AirShieldVariant(hashedSecret: hashed, macKey: mac, macPrefix: prefix, announce: 26)
    }

    /// Candidates for scheme 26, likeliest first. Index 0 is the one verified on September 2026
    /// firmware by air-gestures (`scheme_guess: 0` in band.json).
    public static let scheme26Guesses: [AirShieldVariant] = [
        guess(false, .encryption, true),
        guess(false, .derived, true),
        guess(true, .encryption, false),
        guess(false, .encryption, false),
        guess(true, .encryption, true),
        guess(false, .derived, false),
        guess(true, .derivedHashed, false),
        guess(true, .derivedHashed, true),
    ]
}

public struct AirShieldKeys: Sendable, CustomStringConvertible {
    let encryption: [UInt8]
    let mac: [UInt8]
    let macPrefix: [UInt8]
    /// Pad a block-aligned frame with a whole block, as newer firmware does.
    let padAligned: Bool

    public var description: String { "AirShieldKeys(redacted)" }

    init(encryption: [UInt8], mac: [UInt8], macPrefix: [UInt8] = [], padAligned: Bool = false) {
        self.encryption = encryption
        self.mac = mac
        self.macPrefix = macPrefix
        self.padAligned = padAligned
    }

    /// For tests: fixed keys without a prefix or aligned padding.
    public static func fixed(encryption: [UInt8], mac: [UInt8]) -> AirShieldKeys {
        AirShieldKeys(encryption: encryption, mac: mac)
    }

    /// Keys for one direction: `challenge` is the receiver's RequestEncryption challenge (C),
    /// `seed` the sender's EnableEncryption seed (R).
    public static func derive(_ variant: AirShieldVariant, secret: [UInt8], challenge: [UInt8], seed: [UInt8]) throws -> AirShieldKeys {
        guard secret.count == 32, challenge.count == 16, seed.count == 32 else {
            throw perr("Invalid AirShield key material")
        }
        let hashed = Array(SHA256.hash(data: secret))
        let encryption = variant.hashedSecret
            ? hkdf(hashed, salt: Array(SHA256.hash(data: hashed + challenge + seed)))
            : hkdf(secret, salt: Array(SHA256.hash(data: challenge + seed)))
        let mac: [UInt8]
        switch variant.macKey {
        case .encryption: mac = encryption
        case .derived: mac = hkdf(secret, salt: Array(SHA256.hash(data: seed + challenge + Array("hmac_derive".utf8))))
        case .derivedHashed:
            mac = hkdf(hashed, salt: Array(SHA256.hash(data: seed + challenge + Array("hmac_derive".utf8) + hashed)))
        }
        return AirShieldKeys(encryption: encryption, mac: mac,
                             macPrefix: variant.macPrefix ? [2, 2, 0, 0] : [],
                             padAligned: variant.announce != 3)
    }

    /// For tests that compare against published vectors.
    public var encryptionKeyForTesting: [UInt8] { encryption }
    public var macKeyForTesting: [UInt8] { mac }

    private static func hkdf(_ ikm: [UInt8], salt: [UInt8]) -> [UInt8] {
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: ikm), salt: salt,
                                         info: Array("AirShield".utf8), outputByteCount: 32)
        return key.withUnsafeBytes { Array($0) }
    }
}

private func aesCBC(_ data: [UInt8], key: [UInt8], iv: [UInt8], encrypt: Bool) throws -> [UInt8] {
    guard key.count == 32, iv.count == 16, !data.isEmpty, data.count.isMultiple(of: 16) else {
        throw perr("Invalid AES block shape")
    }
    var output = [UInt8](repeating: 0, count: data.count + 16)
    var moved = 0
    let capacity = output.count
    let status = CCCrypt(CCOperation(encrypt ? kCCEncrypt : kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), 0,
                         key, 32, iv, data, data.count, &output, capacity, &moved)
    guard status == kCCSuccess else { throw perr("AES operation failed") }
    return Array(output.prefix(moved))
}

public struct AirShieldCipher: Sendable {
    let keys: AirShieldKeys
    public private(set) var iv: [UInt8]
    public private(set) var counter: UInt32

    public init(keys: AirShieldKeys, iv: [UInt8], counter: UInt32) {
        self.keys = keys
        self.iv = iv
        self.counter = counter
    }

    public var padsAligned: Bool { keys.padAligned }

    private func tag(_ body: ArraySlice<UInt8>) -> [UInt8] {
        var mac = HMAC<SHA256>(key: SymmetricKey(data: keys.mac))
        mac.update(data: keys.macPrefix)
        mac.update(data: Bytes.le(counter))
        mac.update(data: Array(body))
        return Array(mac.finalize())
    }

    public mutating func encrypt(_ frame: [UInt8]) throws -> [UInt8] {
        var count = 16 - frame.count % 16
        if count == 16 && !keys.padAligned { count = 0 }
        let padded = frame + [UInt8](repeating: UInt8(0xc0 + count), count: count)
        guard !padded.isEmpty, padded.count <= 4096 else { throw perr("AirShield frame too large") }
        let ciphertext = try aesCBC(padded, key: keys.encryption, iv: iv, encrypt: true)
        let body = [UInt8(ciphertext.count / 16 - 1)] + ciphertext
        let tag = tag(body[...])
        iv = Array(ciphertext.suffix(16))
        counter &+= 1
        return [0x40] + tag.prefix(8) + body
    }

    /// Verifies the MAC over every byte before decrypting; a failure leaves IV and counter untouched.
    public mutating func decrypt(_ packet: [UInt8]) throws -> [UInt8] {
        guard packet.count >= 10 else { throw perr("Truncated AirShield packet") }
        let expected = tag(packet[9...])
        var difference: UInt8 = 0
        for index in 0..<8 { difference |= expected[index] ^ packet[1 + index] }
        guard difference == 0 else { throw perr("Band packet authentication failed") }
        let ciphertext = Array(packet[10...])
        guard !ciphertext.isEmpty, ciphertext.count.isMultiple(of: 16) else { throw perr("Invalid AES block shape") }
        let plaintext = try aesCBC(ciphertext, key: keys.encryption, iv: iv, encrypt: false)
        iv = Array(ciphertext.suffix(16))
        counter &+= 1
        return plaintext
    }
}

/// Splits the L2CAP byte stream into AirShield records. `0x81/0x82 xx` (xx ≤ 1) and
/// `0x01/0x02 len …` control markers are skipped; `0x41/0x42` relay records are skipped unread;
/// `0x40` records are authenticated and decrypted.
public struct AirShieldReceiver: Sendable {
    public var cipher: AirShieldCipher
    private var pending: [UInt8] = []
    public private(set) var skippedRecords = 0

    public init(cipher: AirShieldCipher) { self.cipher = cipher }

    public mutating func feed(_ bytes: [UInt8]) throws -> [[UInt8]] {
        pending += bytes
        var plaintext: [[UInt8]] = []
        var start = 0
        defer { if start > 0 { pending.removeFirst(start) } }
        while start < pending.count {
            let marker = pending[start]
            let available = pending.count - start
            let shortControl = marker == 0x81 || marker == 0x82
            if shortControl, available >= 2, pending[start + 1] <= 1 {
                skippedRecords += 1
                start += 2
                continue
            }
            if marker == 0x01 || marker == 0x02 {
                guard available >= 2 else { break }
                let size = 3 + Int(pending[start + 1])
                guard available >= size else { break }
                skippedRecords += 1
                start += size
                continue
            }
            if shortControl, available < 2 { break }
            guard (0x40...0x42).contains(marker) else { throw perr("Unsupported band transport marker") }
            guard available >= 10 else { break }
            let size = 10 + (Int(pending[start + 9]) + 1) * 16
            guard available >= size else { break }
            if marker == 0x40 {
                plaintext.append(try cipher.decrypt(Array(pending[start..<start + size])))
            } else {
                skippedRecords += 1
            }
            start += size
        }
        return plaintext
    }

    public var isDrained: Bool { pending.isEmpty }
}
