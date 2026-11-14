import CryptoKit
import Foundation
@testable import BandProtocol

/// The band's side of a connection, driven by bytes, for tests. Modeled on band-core `responder.rs`
/// and the September 2026 firmware observations: scheme 26 (guess 0), padded records, and extra
/// channel bits (0x1c00) on channels the band answers.
final class SimulatedBand {
    enum Mode { case enrolled, ceremony, legacy }

    let mode: Mode
    let variant: AirShieldVariant
    let bandKey = P256.Signing.PrivateKey()
    var ownerHash: [UInt8]?
    var rejectIdentity: UInt32?
    var rejectClaim: UInt32?
    var hand: UInt64 = 0
    /// Older (scheme-3) firmware: sends its trust proof when the identity service opens, and answers
    /// the identity read only after that proof is acknowledged.
    var earlyProof = false
    /// The settings service (older-firmware layout): id → (name, value). 26 is a decoy that must never be written.
    var settings: [Int: (name: String, value: UInt64)] = [26: ("settings-reset", 0), 27: ("data-collection", 0), 28: ("data-collection-model", 2)]
    private(set) var settingWrites: [(Int, UInt64)] = []
    var modelStreams = false
    /// Experimental stream flags (anything beyond 2/3/4/6/8/22/23) as last set.
    private(set) var extraStreams: [UInt32: UInt64] = [:]
    /// Newer firmware: a firmware log on the settings channel when data collection starts, after
    /// which answers there carry no kind word (the band names a channel's kind only when it changes).
    var logsWhenCollecting = false
    /// Updated firmware refuses the config service (0x8007) with error word 0x0300c003.
    var refusesConfigService = false
    private var settingsUnnamed = false
    func setting(_ name: String) -> UInt64? { settings.values.first { $0.name == name }?.value }
    var handwritingOn: Bool { setting("data-collection") == 1 && setting("data-collection-model") == 5 && modelStreams }
    /// The update service: what the band runs, holds staged, and has received.
    struct Ota {
        var state: UInt64 = 1
        var active: UInt64 = 100
        var staged: UInt64 = 100
        var ml: UInt64 = 5
        var kek: UInt64 = 1
        var item: (kind: UInt64, version: UInt64, size: Int)?
        var md5: [UInt8] = []
        var buffer: [UInt8] = []
        var verified: [UInt64: [UInt8]] = [:]
        var committed = false
        var steps: [UInt32] = []
    }
    var ota = Ota()
    private var awaitingProofAck = false
    private(set) var earlyProofAcked = false

    private let secret = P256.KeyAgreement.PrivateKey()
    private let challenge = Bytes.random(16)
    private let seed = Bytes.random(32)
    private let iv = Bytes.random(16)
    private let base = UInt32.random(in: .min ... .max)
    private var hostPoint: [UInt8]?
    private var hostChallenge: [UInt8]?
    private var pending: [UInt8] = []
    private var transmitter: AirShieldCipher?
    private var receiver: AirShieldReceiver?
    private var datax = DataXReceiver()
    private var sequence: UInt64 = 0
    private(set) var received: [DataXFrame] = []
    private(set) var hapticsSeen: [[UInt8]] = []
    private(set) var finishSeen = false

    init(mode: Mode, variant: AirShieldVariant = AirShieldVariant.scheme26Guesses[0]) {
        self.mode = mode
        self.variant = variant
        if variant.announce != 3 { datax.setAlwaysPadded() }
    }

    var publicPoint: [UInt8] { Array(secret.publicKey.rawRepresentation) }
    var bandPoint: [UInt8] { Array(bandKey.publicKey.rawRepresentation) }

    func respond(_ bytes: [UInt8]) throws -> [UInt8] {
        pending += bytes
        var out: [UInt8] = []
        while transmitter == nil, pending.count >= 4 {
            let size = Int(Bytes.be16(pending, 0) & 0x7fff) + 4
            guard pending.count >= size else { break }
            let frame = Array(pending.prefix(size))
            pending.removeFirst(size)
            let offset = frame[2] & 0x80 != 0 ? 8 : 4
            let kind = Bytes.be32(frame, offset)
            let fields = try ProtoFields(parsing: Array(frame[(offset + 4)...]))
            if kind == 0x0200_0001 {
                hostPoint = try fields.bytes(1, count: 64)
                hostChallenge = try fields.bytes(2, count: 16)
                out += try DataX.encode(channel: 1, words: [0x0200_0001],
                    payload: Proto.field(1, bytes: publicPoint) + Proto.field(2, bytes: challenge) + Proto.field(3, 0) + Proto.field(4, variant.announce == 3 ? 3 : 27))
            } else if kind == 0x0200_0002 {
                let hostSeed = try fields.bytes(2, count: 32)
                let hostIV = try fields.bytes(3, count: 16)
                let hostCounter = UInt32(try fields.integer(4))
                let peer = try P256.KeyAgreement.PublicKey(rawRepresentation: hostPoint!)
                let shared = try secret.sharedSecretFromKeyAgreement(with: peer).withUnsafeBytes { Array($0) }
                receiver = AirShieldReceiver(cipher: AirShieldCipher(
                    keys: try .derive(variant, secret: shared, challenge: challenge, seed: hostSeed), iv: hostIV, counter: hostCounter))
                transmitter = AirShieldCipher(keys: try .derive(variant, secret: shared, challenge: hostChallenge!, seed: seed), iv: iv, counter: base)
                self.hostSeed = hostSeed
                out += try DataX.encode(channel: 1, words: [0x0200_0002],
                    payload: Proto.field(1, bytes: publicPoint) + Proto.field(2, bytes: seed) + Proto.field(3, bytes: iv)
                        + Proto.field(4, UInt64(base)) + Proto.field(5, variant.announce))
            }
        }
        guard receiver != nil, !pending.isEmpty else { return out }
        let records = try receiver!.feed(pending)
        pending.removeAll()
        for record in records {
            for frame in try datax.feed(record) {
                received.append(frame)
                out += try answer(frame)
            }
        }
        return out
    }

    private var hostSeed: [UInt8]?

    private func send(_ channel: UInt16, _ word: UInt32?, _ payload: [UInt8] = [], open: Bool = false) throws -> [UInt8] {
        let words = (open ? [0x8100_0024] : []) + (word.map { [$0] } ?? [])
        return try transmitter!.encrypt(DataX.encode(channel: channel, words: words, payload: payload))
    }

    private func earlyProofFrame() throws -> [UInt8] {
        // Observed on firmware 79a235830f7f: ch 0x8003 words [81000024, 02001001], 80 bytes.
        try send(0x8003, 0x0200_1001, Proto.field(1, bytes: [1]) + Proto.field(2, bytes: Bytes.random(64)) + Proto.field(3, 1), open: true)
    }

    private func identityResponse() throws -> [UInt8] {
        let certificate = [UInt8](repeating: 7, count: 300)
        return try send(0x1c02, 0x0200_3001,
                        Proto.field(1, bytes: certificate) + Proto.field(2, bytes: Array("SIMBAND0001".utf8)) + Proto.field(5, bytes: certificate))
    }

    private func trustProof() throws -> [UInt8] {
        let digest = trustDigest(challenge: hostChallenge!, receiver: hostPoint!, seed: seed, sender: publicPoint)
        let signature = try bandKey.signature(for: digest).rawRepresentation
        return try send(0x9c03, 0x0200_1001, Proto.field(1, bytes: [1]) + Proto.field(2, bytes: Array(signature)))
    }

    private func answer(_ frame: DataXFrame) throws -> [UInt8] {
        let kind = frame.words.last
        let fields = (try? ProtoFields(parsing: frame.payload))
        switch (frame.channel, kind) {
        case (0x8002, 0x0200_1000):
            let hash = try fields!.bytes(1, count: 32)
            if let reject = rejectIdentity { return try send(0x1c02, reject) }
            if let ownerHash, ownerHash != hash { return try send(0x1c02, 0x0300_1043) }
            ownerHash = hash
            return try send(0x1c02, 0x0300_1000) + trustProof()
        case (0x8002, 0x0200_3000):
            if earlyProof {
                awaitingProofAck = mode == .ceremony
                return try earlyProofFrame()
            }
            return mode == .legacy ? [] : try identityResponse()
        case (0x0003, 0x0300_1000) where awaitingProofAck:
            awaitingProofAck = false
            earlyProofAcked = true
            return try identityResponse()
        case (0x8002, 0x0200_2000):
            return try send(0x1c02, 0x0200_2001, Proto.field(1, bytes: Bytes.random(16)))
        case (0x8002, 0x0200_2002):
            if let reject = rejectClaim { return try send(0x1c02, reject) }
            return try send(0x1c02, 0x0200_2003, Proto.field(1, bytes: [9, 9]) + Proto.field(2, bytes: Array("{\"receipt_type\":\"DevicePendingOwnershipReceipt\"}".utf8)))
        case (0x8002, 0x0200_2004):
            finishSeen = true
            return try send(0x1c02, 0x0200_2005)
        case (0x0003, 0x0300_1000), (0x1c03, 0x0300_1000):
            earlyProofAcked = true
            return []
        case (0x8001, 0x0200_1000):
            return try send(0x9c01, 0x0200_1000, Proto.field(1, 1) + Proto.field(2, bytes: Bytes.random(16)))
        case (0x8003, _):
            let info = Proto.field(2, bytes: Array("1054928927".utf8)) + Proto.field(4, bytes: Array("PVT".utf8))
                + Proto.field(5, bytes: Array("cc_od_v2".utf8)) + Proto.field(6, bytes: Array("SIMBAND0001".utf8))
            return try send(0x1c03, 0x0200_0315, Proto.field(1, 1) + Proto.field(2, 1) + Proto.field(3, bytes: Proto.field(5, bytes: info)))
        case (0x8001, _) where fields?.contains(14) == true:
            let request = try fields!.integer(1)
            let body = try ProtoFields(parsing: try fields!.bytes(14))
            func reply(_ inner: [UInt8], ok: Bool = true) throws -> [UInt8] {
                try send(0x1c01, settingsUnnamed ? nil : 0x0200_0315, Proto.field(1, request) + Proto.field(2, ok ? 1 : 0) + Proto.field(14, bytes: inner))
            }
            if body.contains(1) { return try reply(Proto.field(1, bytes: Proto.field(1, UInt64(settings.keys.max() ?? 0)))) }
            if body.contains(2) {
                let id = Int(try ProtoFields(parsing: try body.bytes(2)).integer(2))
                // Updated firmware answers id 0 with "ok" and no description at all.
                if id == 0 { return try reply([]) }
                guard let setting = settings[id] else { return try reply([], ok: false) }
                return try reply(Proto.field(2, bytes: Proto.field(3, bytes: Array(setting.name.utf8)) + Proto.field(4, UInt64(id))))
            }
            let op = try ProtoFields(parsing: try body.bytes(3))
            let id = Int(try op.integer(1))
            guard var setting = settings[id] else { return try reply([], ok: false) }
            let isBool = setting.name == "data-collection"
            if try op.integer(2) == 1 {
                let value = try ProtoFields(parsing: try op.bytes(isBool ? 7 : 10)).integer(1)
                setting.value = value
                settings[id] = setting
                settingWrites.append((id, value))
                if logsWhenCollecting, isBool, value == 1, !settingsUnnamed {
                    let log = try send(0x1c01, 0x0200_0316, Proto.field(3, bytes: Proto.field(1, bytes: Array("data collection started".utf8))))
                    settingsUnnamed = true
                    return try log + reply(Proto.field(3, bytes: Proto.field(1, UInt64(id)) + Proto.field(2, 1) + Proto.field(3, 0)))
                }
                return try reply(Proto.field(3, bytes: Proto.field(1, UInt64(id)) + Proto.field(2, 1) + Proto.field(3, 0)))
            }
            return try reply(Proto.field(3, bytes: Proto.field(1, UInt64(id)) + Proto.field(2, 0) + Proto.field(3, 0)
                                          + Proto.field(isBool ? 8 : 11, bytes: Proto.field(1, setting.value))))
        case (0x8007, _) where refusesConfigService:
            return try send(0x1c07, 0x0300_c003)
        case (0x8007, _):
            let request = try fields!.integer(1)
            return try send(0x1c07, 0x0200_0315, Proto.field(1, request) + Proto.field(2, 1) + Proto.field(6, bytes: Proto.field(1, 1)))
        case (0x8005, _):
            let request = try fields!.integer(1)
            let control = (try? fields!.bytes(4)).flatMap { try? ProtoFields(parsing: $0) }
            if request == 2 { return [] }
            let on: UInt64 = request == 4 ? 0 : 1
            var flags = Proto.field(3, on) + Proto.field(6, on) + Proto.field(8, on)
            if let control, control.contains(2) { flags = Proto.field(2, try control.integer(2)) + flags }
            if let control, control.contains(4) {
                modelStreams = try control.integer(4) == 1
                for field in [UInt32(4), 22, 23] { flags += Proto.field(field, try control.integer(field)) }
            }
            if let control {
                for field in control.fieldNumbers where ![2, 3, 4, 6, 8, 22, 23].contains(field) {
                    extraStreams[field] = try control.integer(field)
                }
            }
            for (field, value) in extraStreams.sorted(by: { $0.key < $1.key }) { flags += Proto.field(field, value) }
            return try send(0x1c05, 0x0200_0315, Proto.field(1, request) + Proto.field(2, 1) + Proto.field(5, bytes: flags))
        case (0x8006, _):
            let request = try fields!.integer(1)
            if fields!.contains(17) {
                hapticsSeen.append(try fields!.bytes(17))
                let haptics = Proto.field(1, 0) + Proto.field(2, bytes: [])
                return try send(0x1c06, 0x0200_0315, Proto.field(1, request) + Proto.field(2, 1) + Proto.field(18, bytes: haptics))
            }
            if fields!.contains(7) || fields!.contains(9) {
                return try updateService(request: request, fields: fields!)
            }
            let config = Proto.field(10, hand)
            return try send(0x1c06, 0x0200_0315, Proto.field(1, request) + Proto.field(2, 1) + Proto.field(6, bytes: config))
        case (0x8008, _):
            let request = try fields!.integer(1)
            let battery = Proto.field(1, bytes: Proto.field(1, 77) + Proto.field(2, 1))
            return try send(0x1c08, 0x0200_0315, Proto.field(1, request) + Proto.field(2, 1) + Proto.field(3, bytes: battery))
        default:
            return []
        }
    }

    private func updateService(request: UInt64, fields: ProtoFields) throws -> [UInt8] {
        func reply(_ field: UInt32, _ body: [UInt8]) throws -> [UInt8] {
            try send(0x1c06, 0x0200_0315, Proto.field(1, request) + Proto.field(2, 1) + Proto.field(field, bytes: body))
        }
        func general(_ code: UInt64) throws -> [UInt8] { try reply(8, Proto.field(1, bytes: Proto.field(1, bytes: Proto.field(1, code)))) }
        if let bulk = try? ProtoFields(parsing: fields.bytes(9)) {
            if let info = try? ProtoFields(parsing: bulk.bytes(1)) {
                ota.md5 = try info.bytes(1)
                ota.buffer = []
                return try reply(10, Proto.field(1, bytes: Proto.field(1, 1) + Proto.field(2, 4 * 950) + Proto.field(3, 0)))
            }
            let chunk = try ProtoFields(parsing: bulk.bytes(2))
            let offset = try chunk.integer(2)
            guard Int(offset) == ota.buffer.count else {
                return try reply(10, Proto.field(3, bytes: Proto.field(2, bytes: Array("out of order".utf8))))
            }
            ota.buffer += try chunk.bytes(3)
            return try reply(10, Proto.field(2, bytes: Proto.field(1, try chunk.integer(1)) + Proto.field(2, offset)))
        }
        let body = try ProtoFields(parsing: fields.bytes(7))
        let step = body.fieldNumbers.first ?? 0
        ota.steps.append(step)
        switch step {
        case 1:
            let item = { (kind: UInt64, version: UInt64) in Proto.field(5, bytes: Proto.field(1, kind) + Proto.field(2, version)) }
            let info = Proto.field(2, 1) + Proto.field(3, 0) + Proto.field(4, ota.state) + item(0, ota.active) + item(1, ota.staged) + item(2, ota.ml)
                + Proto.field(6, ota.kek)
            return try reply(8, Proto.field(2, bytes: info))
        case 6:
            ota.kek = try ProtoFields(parsing: body.bytes(6)).integer(1)
            return try general(0)
        case 2:
            let start = try ProtoFields(parsing: body.bytes(2))
            let info = try ProtoFields(parsing: start.bytes(1))
            let version = try info.integer(2)
            guard version > ota.active else { return try general(202) }
            ota.item = (try info.integer(1), version, Int(try start.integer(2)))
            ota.state = 2
            return try general(0)
        case 3:
            guard let item = ota.item, ota.buffer.count == item.size, Array(Insecure.MD5.hash(data: ota.buffer)) == ota.md5 else {
                return try reply(8, Proto.field(3, bytes: Proto.field(1, bytes: Proto.field(1, 300))))
            }
            ota.verified[item.kind] = ota.buffer
            if item.kind == 0 { ota.staged = item.version }
            ota.state = 3
            return try reply(8, Proto.field(3, bytes: Proto.field(1, bytes: [])))
        case 5:
            ota.state = 1
            ota.staged = ota.active
            ota.verified = [:]
            return try general(0)
        case 4:
            guard ota.state == 3 else { return try reply(8, Proto.field(4, bytes: Proto.field(1, bytes: Proto.field(1, 205)))) }
            ota.active = ota.staged
            ota.committed = true
            ota.state = 1
            return try reply(8, Proto.field(4, bytes: Proto.field(1, bytes: []) + Proto.field(2, 1)))
        default:
            return try general(100)
        }
    }

    /// A band gesture message on the stream channel (finger, action, derived enum values).
    func gesture(finger: UInt64, action: UInt64, derived: UInt64) throws -> [UInt8] {
        sequence += 1
        return try send(0x1c05, 0x0200_020d, Proto.field(1, sequence) + Proto.field(2, 1_000 * sequence)
                        + Proto.field(3, finger) + Proto.field(4, action) + Proto.field(5, derived))
    }

    /// One handwriting-model frame (pipeline 3): log-probabilities with `best` at ~0.9.
    func inference(best: Int) throws -> [UInt8] {
        sequence += 1
        var probabilities = [Float](repeating: 0.1 / 99, count: 100)
        probabilities[best] = 0.9
        let bytes = probabilities.flatMap { value -> [UInt8] in
            let bits = log(value).bitPattern
            return [UInt8(bits & 0xff), UInt8((bits >> 8) & 0xff), UInt8((bits >> 16) & 0xff), UInt8(bits >> 24)]
        }
        return try send(0x1c05, 0x0200_020c, Proto.field(1, sequence) + Proto.field(2, 1000 * sequence) + Proto.field(3, bytes: bytes) + Proto.field(10, 3))
    }

    func gyro(_ x: Int16, _ y: Int16, _ z: Int16, timestamp: UInt64) throws -> [UInt8] {
        sequence += 1
        let raw = [x, y, z].flatMap { value -> [UInt8] in
            let bits = UInt16(bitPattern: value)
            return [UInt8(bits & 0xff), UInt8(bits >> 8)]
        }
        return try send(0x1c05, 0x0200_020f, Proto.field(1, sequence) + Proto.field(2, timestamp) + Proto.field(3, bytes: raw))
    }
}
