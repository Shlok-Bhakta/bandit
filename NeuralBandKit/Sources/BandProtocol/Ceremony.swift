import CryptoKit
import Foundation

/// The BLE side of the one-time ownership ceremony (band-core `ceremony.rs`).
///
/// Sequence: identity read (0x3000→0x3001), skip challenge (0x2000→0x2001, yields the nonce),
/// [HTTP pair_request], StartChangeOwner (0x2002→0x2003), [HTTP pair],
/// FinishChangeOwner (0x2004→0x2005). Receipts stay verbatim: they are signed bytes.
public enum Ceremony {
    public static let factoryResetHint = "hold its button for about 16 seconds"

    /// The reference error map for identity-service result codes.
    public static func failureMessage(_ code: UInt32) -> String {
        switch code {
        case 0x1040: "The band rejected the ownership receipt."
        case 0x1041: "The band rejected the ownership challenge."
        case 0x1042: "This band belongs to a different Meta account. Sign in with that account, or factory reset the band (\(factoryResetHint)) to claim it with this one."
        case 0x1043: "The band rejected this app's identity."
        case 0x1044: "The band rejected a signature."
        case 0x1045: "The band rejected the receipt timing (check the iPhone's clock)."
        case 0xd001, 0xd004, 0xd021: "The band couldn't read the ownership request."
        case 0xc001: "The band has no identity service. Put it in pairing mode (hold the button ~3 s until it flashes)."
        case 0xc004: "The band couldn't parse the ownership request."
        default: "The band reported an ownership error (0x\(String(code, radix: 16)))."
        }
    }
}

/// What a band in pairing mode reports; sent verbatim to the ownership endpoints.
public struct BandIdentityInfo: Sendable, Equatable, CustomStringConvertible {
    public let deviceCertificate: [UInt8]
    public let serial: String
    public let secondaryCertificate: [UInt8]
    public var description: String { "BandIdentityInfo(cert \(deviceCertificate.count)B, secondary \(secondaryCertificate.count)B)" }
}

/// Input for the `pair_request` HTTP call.
public struct CeremonyPairRequest: Sendable, CustomStringConvertible {
    public let identity: BandIdentityInfo
    public let nonce: [UInt8]
    public let appPublicKey: [UInt8]
    public var description: String { "CeremonyPairRequest(nonce \(nonce.count)B)" }
}

/// Input for the `pair` HTTP call.
public struct CeremonyPair: Sendable, CustomStringConvertible {
    public let receipt: String
    public let signature: [UInt8]
    public var description: String { "CeremonyPair(receipt \(receipt.count) chars)" }
}

public enum CeremonyHttpRequest: Sendable {
    case pairRequest(CeremonyPairRequest)
    case pair(CeremonyPair)
}

struct OwnershipCeremony: Sendable {
    enum Stage: Sendable { case identityRead, skipChallenge, startChangeOwner, pair, finishChangeOwner, done }

    private(set) var stage: Stage = .identityRead
    /// A fresh owner key for this attempt; stored only once the band may commit.
    let appKey: P256.Signing.PrivateKey
    private(set) var identity: BandIdentityInfo?
    private var devicePublicKey: [UInt8]?

    init(appKey: P256.Signing.PrivateKey = P256.Signing.PrivateKey()) {
        self.appKey = appKey
    }

    var appPublicKey: [UInt8] { Array(appKey.publicKey.rawRepresentation) }

    /// The identity read that opens the identity service on channel 0x8002.
    func start() throws -> [UInt8] {
        guard stage == .identityRead else { throw perr("The enrollment is past its identity read") }
        return try DataX.encode(channel: 0x8002, words: [0x8100_0024, 0x0200_3000])
    }

    mutating func identityRead(_ payload: [UInt8]) throws -> [UInt8] {
        guard stage == .identityRead else { throw perr("The band sent an unexpected identity response") }
        let fields = try ProtoFields(parsing: payload)
        let certificate = try fields.bytes(1)
        let serialBytes = try fields.bytes(2)
        let secondary = try fields.bytes(5)
        guard let serial = String(bytes: serialBytes, encoding: .ascii), !serial.isEmpty,
              certificate.count > 256, secondary.count > 256 else {
            throw perr("The band didn't report a usable identity")
        }
        identity = BandIdentityInfo(deviceCertificate: certificate, serial: serial, secondaryCertificate: secondary)
        stage = .skipChallenge
        return try DataX.encode(channel: 0x8002, words: [0x0200_2000])
    }

    mutating func skipChallenge(_ payload: [UInt8]) throws -> CeremonyPairRequest {
        guard stage == .skipChallenge, let identity else { throw perr("The band sent an unexpected challenge response") }
        let nonce = try ProtoFields(parsing: payload).bytes(1, count: 16)
        stage = .startChangeOwner
        return CeremonyPairRequest(identity: identity, nonce: nonce, appPublicKey: appPublicKey)
    }

    mutating func pairRequestCompleted(signature: [UInt8], receipt: String) throws -> [UInt8] {
        guard stage == .startChangeOwner else { throw perr("The enrollment isn't waiting for its claim") }
        guard !signature.isEmpty, !receipt.isEmpty else { throw perr("Meta didn't return a pending ownership receipt") }
        stage = .pair
        return try DataX.encode(channel: 0x8002, words: [0x0200_2002],
                                payload: Proto.field(1, bytes: signature) + Proto.field(2, bytes: Array(receipt.utf8)))
    }

    mutating func startChangeOwner(_ payload: [UInt8]) throws -> CeremonyPair {
        guard stage == .pair else { throw perr("The band sent an unexpected ownership response") }
        let fields = try ProtoFields(parsing: payload)
        let signature = try fields.bytes(1)
        guard let receipt = String(bytes: try fields.bytes(2), encoding: .utf8), !receipt.isEmpty else {
            throw perr("The band didn't return its pending ownership receipt")
        }
        stage = .finishChangeOwner
        return CeremonyPair(receipt: receipt, signature: signature)
    }

    /// A missing device key is tolerated (the band's trust proof then stays unverified).
    mutating func pairCompleted(signature: [UInt8], receipt: String, devicePublicKey: [UInt8]?) throws -> [UInt8] {
        guard stage == .finishChangeOwner else { throw perr("The enrollment isn't waiting for its final receipt") }
        guard !signature.isEmpty, !receipt.isEmpty else { throw perr("Meta didn't return a final ownership receipt") }
        var point: [UInt8]?
        if let key = devicePublicKey {
            if key.count == 64 { point = key } else if key.count == 65, key[0] == 4 { point = Array(key[1...]) } else {
                throw perr("Meta returned an invalid band key")
            }
            _ = try verifyingKey(point: point!)
        }
        self.devicePublicKey = point
        stage = .done
        return try DataX.encode(channel: 0x8002, words: [0x0200_2004],
                                payload: Proto.field(1, bytes: signature) + Proto.field(2, bytes: Array(receipt.utf8)))
    }

    /// The identity FinishChangeOwner asks the band to commit. Non-nil once `pairCompleted` succeeded.
    var pendingIdentity: OwnerIdentity? {
        guard stage == .done else { return nil }
        return OwnerIdentity(privateKey: appKey, bandPublicKey: devicePublicKey.flatMap { try? verifyingKey(point: $0) })
    }

    func complete(words: [UInt32], payload: [UInt8]) throws -> OwnerIdentity {
        guard stage == .done else { throw perr("The enrollment isn't ready to finish") }
        guard words == [0x0200_2005], payload.isEmpty else { throw perr("The band didn't confirm the ownership change") }
        return pendingIdentity!
    }
}
