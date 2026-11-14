import CryptoKit
import Foundation

/// `SHA256(SHA256(receiver challenge || receiver key) || SHA256(sender seed || sender key))`.
/// Returned as a CryptoKit digest so it can be signed as a prehash (ECDSA over the digest bytes).
func trustDigest(challenge: [UInt8], receiver: [UInt8], seed: [UInt8], sender: [UInt8]) -> SHA256Digest {
    let first = Array(SHA256.hash(data: challenge + receiver))
    let second = Array(SHA256.hash(data: seed + sender))
    return SHA256.hash(data: first + second)
}

/// The owner key that proves this host owns the band (band-core `EnrollmentIdentity`),
/// plus the band's own identity key when Meta returned it.
///
/// Byte layout (air-gestures `owner.key`): the 32-byte P-256 private scalar, optionally
/// followed by the band's 65-byte X9.63 public key — 32 or 97 bytes total.
/// `description` never reveals key material.
public struct OwnerIdentity: Sendable, CustomStringConvertible {
    public let privateKey: P256.Signing.PrivateKey
    public let bandPublicKey: P256.Signing.PublicKey?

    public init(privateKey: P256.Signing.PrivateKey, bandPublicKey: P256.Signing.PublicKey? = nil) {
        self.privateKey = privateKey
        self.bandPublicKey = bandPublicKey
    }

    /// Parses the 32- or 97-byte owner key file. Errors never contain key material.
    public init(ownerKeyBytes bytes: [UInt8]) throws {
        let band: [UInt8]?
        switch bytes.count {
        case 32: band = nil
        case 97: band = Array(bytes[32...])
        default: throw perr("The owner key must be 32 or 97 bytes (this one is \(bytes.count))")
        }
        guard let key = try? P256.Signing.PrivateKey(rawRepresentation: bytes.prefix(32)) else {
            throw perr("The owner key isn't a valid P-256 private key")
        }
        var bandKey: P256.Signing.PublicKey?
        if let band {
            guard let parsed = try? P256.Signing.PublicKey(x963Representation: band) else {
                throw perr("The stored band key isn't a valid P-256 public key")
            }
            bandKey = parsed
        }
        self.init(privateKey: key, bandPublicKey: bandKey)
    }

    /// The air-gestures `owner.key` bytes (32, or 97 with the band key). Secret.
    public var ownerKeyBytes: [UInt8] {
        var bytes = Array(privateKey.rawRepresentation)
        if let bandPublicKey { bytes += Array(bandPublicKey.x963Representation) }
        return bytes
    }

    /// The raw 64-byte `x || y` point of the owner's public key (not secret).
    public var appPoint: [UInt8] { Array(privateKey.publicKey.rawRepresentation) }

    /// A short, non-secret fingerprint of the owner public key, for display and matching.
    public var fingerprint: String {
        let digest = Array(SHA256.hash(data: appPoint))
        return stride(from: 0, to: 8, by: 2).map { String(format: "%02X%02X", digest[$0], digest[$0 + 1]) }
            .joined(separator: "-")
    }

    public var verifiesBand: Bool { bandPublicKey != nil }

    public var description: String { "OwnerIdentity(fingerprint: \(fingerprint), bandKey: \(bandPublicKey != nil))" }

    func sign(_ digest: SHA256Digest) throws -> [UInt8] {
        guard let signature = try? privateKey.signature(for: digest) else {
            throw perr("Could not sign the band trust proof")
        }
        return Array(signature.rawRepresentation)
    }
}

/// A 64-byte `x || y` point (or 65-byte `04`-prefixed one) as a verifying key.
func verifyingKey(point: [UInt8]) throws -> P256.Signing.PublicKey {
    let raw: [UInt8]
    if point.count == 64 { raw = point } else if point.count == 65, point[0] == 4 { raw = Array(point[1...]) } else {
        throw perr("Invalid P-256 public key")
    }
    guard let key = try? P256.Signing.PublicKey(rawRepresentation: raw) else { throw perr("Invalid P-256 public key") }
    return key
}
