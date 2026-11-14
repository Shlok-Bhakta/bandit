import CryptoKit
import Foundation

/// A diagnostic line from the session (types, sizes, codes — never payloads or keys).
public struct SessionNote: Sendable {
    public enum Level: Sendable { case debug, info, notice, warning }
    public let level: Level
    public let text: String
}

/// What one `feed` produced: bytes to write to the band and events to act on.
public struct FeedResult: Sendable {
    public var outgoing: [UInt8] = []
    public var events: [SessionEvent] = []
}

/// How the session authenticates.
public enum SessionMode: Sendable {
    /// No owner key: only bands in pairing mode answer (they usually reject input setup).
    case legacy
    /// Connect as the stored owner (`EnableTrust` proof signed with the owner key).
    case enrolled(OwnerIdentity)
    /// Claim a band in pairing mode with a fresh owner key (needs a Meta session for two HTTP steps).
    case ceremony
}

/// The band handshake, trust setup and input subscription — a sans-IO port of band-core
/// `session.rs` (commit 4b59393, 2026-10-30). Feed it bytes from the L2CAP stream; write back
/// what it returns. Any thrown error from `feed` is terminal: drop the session (after persisting
/// `pendingIdentity` if a ceremony was running — the band may already have changed owner).
public final class BandSession {
    // MARK: constants
    static let streamFields: [UInt32] = [3, 6, 8]
    static let activeRequest: UInt64 = 1 << 20
    static let streamChannel: UInt16 = 0x8005
    static let configurationChannel: UInt16 = 0x8006
    static let configServiceChannel: UInt16 = 0x8007
    static let batteryChannel: UInt16 = 0x8008
    static let serviceOpen: [UInt32] = [0x8100_ce56, 0x0200_0314]
    static let rpcResponse: UInt32 = 0x0200_0315
    static let serviceRejected: UInt32 = 0x0300_c001
    static let rawEmgKind: UInt32 = 0x0200_020a
    /// The band's on-device model output (`RawInferenceSample`): handwriting scores in pipeline 3.
    static let rawInferenceKind: UInt32 = 0x0200_020c
    static let firmwareLogKind: UInt32 = 0x0200_0316
    static let gestureKind: UInt32 = 0x0200_020d
    static let gyroKind: UInt32 = 0x0200_020f
    static let orientationKind: UInt32 = 0x0200_0212
    static let linkSetup: UInt32 = 0x0200_1000
    public static let bandBusy = "The band refused the connection: it is probably connected to another device (a phone, glasses or computer). Disconnect it there and try again."

    /// The channel as the protocol logic knows it: direction flag and low byte. Newer firmware sets
    /// extra bits (0x1c00) on channels it answers or opens.
    static func route(_ channel: UInt16) -> UInt16 { channel & 0x80ff }

    enum SetupStage: String { case link, ceremony, identity, deviceInfo, input }
    enum RawStage { case config, query, update }
    struct RawRequest { var enabled: Bool; var stage: RawStage; var id: UInt64; var deadline: Double }
    struct HandRequest { var id: UInt64; var hand: Hand?; var reading: Bool; var deadline: Double }

    // MARK: handshake state
    private let secret = P256.KeyAgreement.PrivateKey()
    private let publicPoint: [UInt8]
    private let challenge = Bytes.random(16)
    private let seed = Bytes.random(32)
    private let iv = Bytes.random(16)
    private let base = UInt32.random(in: .min ... .max)
    private var peerKey: [UInt8]?
    private var peerChallenge: [UInt8]?
    private var peerSeed: [UInt8]?
    public private(set) var peerParameters: UInt64 = 3
    public let schemeGuess: Int
    public private(set) var variant: AirShieldVariant = .scheme3
    /// The band offered a newer scheme, so `variant` is a guess.
    public private(set) var guessing = false
    private var pending: [UInt8] = []
    private var transmitter: AirShieldCipher?
    private var receiver: AirShieldReceiver?
    private var datax = DataXReceiver()
    private var channelTypes: [UInt16: UInt32] = [:]

    // MARK: session state
    private var notes: [SessionNote] = []
    private var dial = PinchDial()
    private var emittedEngagement = false
    private var dialPending = 0.0
    private var lastDial = -Double.infinity
    private var lastHeartbeat = -Double.infinity
    public private(set) var streaming = false
    public private(set) var stopping = false
    public private(set) var stopAcknowledged = false
    public private(set) var streamsEnabled = false
    private var batteryChannelOpened = false
    private var batteryRequestID: UInt64 = 0
    private var batteryRequest: (id: UInt64, deadline: Double)?
    public private(set) var batteryUnavailable = false
    private var rawEmg: Bool
    private var rawRequested = false
    private var configServiceOpened = false
    private let modelCapture = ModelCapture()
    /// The settings service on 0x8001 was opened (its first request carries `serviceOpen`).
    private var settingsOpened = false
    private let survey = BandSurvey()
    /// Experimental stream flags the user turned on or off (never 2, 3, 6, 8: the session owns those).
    public private(set) var probeFlags: [UInt32: Bool] = [:]
    private var probeRequestID: UInt64 = 0x3000_0000
    /// The latest field shape (no byte contents) of each message kind the session doesn't decode.
    public private(set) var unknownShapes: [UInt32: String] = [:]
    private var otaJob: OtaJob?
    /// Gyro and orientation (6, 8) are off while an update runs, as band-core does: less traffic.
    private var otaQuiet = false
    /// The band's latest update status, from a job or the survey.
    public private(set) var otaLast: OtaStatus?
    private var rawRequestID: UInt64 = 6
    private var rawRequest: RawRequest?
    private var setupStage = SetupStage.link
    public private(set) var enrollment: OwnerIdentity?
    private var ceremony: OwnershipCeremony?
    private var appTrusted = false
    private var bandTrusted = false
    private var endLinkSent = false
    private var earlyProofAcknowledged = false
    private var configurationID: UInt64 = 0
    private var handRequest: HandRequest?
    private var hapticsRequest: (id: UInt64, deadline: Double, field: UInt32)?
    private var configurationRequests: [(id: UInt64, deadline: Double)] = []
    private var lastClock = 0.0
    public private(set) var hand: Hand?
    public private(set) var deviceInfo: DeviceInfo?
    /// Log every frame header after setup.
    public var logFrames = false
    /// Developer probes only: hex-dump decrypted setup-frame payloads (capped; receipts skipped).
    /// Never enable in the shipping app: the app's logs promise no payloads.
    public var dumpSetupPayloads = false

    // MARK: counters (diagnostics)
    public private(set) var authenticatedPackets = 0
    public private(set) var framesDecoded = 0
    public private(set) var motionMessages = 0
    public private(set) var gestureMessages = 0
    public private(set) var orientationMessages = 0
    public private(set) var rawEmgFrames = 0
    public private(set) var rawEmgBytes = 0
    public private(set) var decodeFailures = 0
    public private(set) var unknownKinds: [UInt32: Int] = [:]
    /// Every frame by message kind.
    public private(set) var kindCounts: [UInt32: Int] = [:]
    public var skippedTransportRecords: Int { receiver?.skippedRecords ?? 0 }
    public var stageName: String { setupStage.rawValue }

    public init(mode: SessionMode, rawEmg: Bool = false, schemeGuess: Int = 0) {
        publicPoint = Array(secret.publicKey.rawRepresentation)
        self.rawEmg = rawEmg
        self.schemeGuess = schemeGuess
        switch mode {
        case .legacy: break
        case .enrolled(let identity): enrollment = identity
        case .ceremony: ceremony = OwnershipCeremony()
        }
    }

    public var isCeremony: Bool { ceremony != nil }
    /// Keys are derived (both encryption messages exchanged); a later failure with no
    /// authenticated packet means a wrong scheme-26 key guess.
    public var encryptionEstablished: Bool { receiver != nil }
    public var rawEmgRequested: Bool { rawEmg }
    /// The identity FinishChangeOwner asks the band to commit, once `ceremonyPairCompleted` ran.
    public var pendingIdentity: OwnerIdentity? { ceremony?.pendingIdentity }
    public var bandVerified: Bool { enrollment?.bandPublicKey != nil }

    public func takeNotes() -> [SessionNote] {
        defer { notes.removeAll() }
        return notes
    }

    private func note(_ level: SessionNote.Level, _ text: String) { notes.append(SessionNote(level: level, text: text)) }

    // MARK: outgoing

    /// The first bytes to write after the L2CAP channel opens: RequestEncryption.
    public func request() throws -> [UInt8] {
        // Field 4 is the bitmask of schemes we support, as the phone app offers (31).
        try DataX.encode(channel: 0x8001, words: [0x8100_0005, 0x0200_0001],
                         payload: Proto.field(1, bytes: publicPoint) + Proto.field(2, bytes: challenge)
                            + Proto.field(3, 0) + Proto.field(4, 31) + Proto.field(7, 16))
    }

    private func encrypt(_ frame: [UInt8]) throws -> [UInt8] {
        guard transmitter != nil else { throw perr("Band encryption is not ready") }
        return try transmitter!.encrypt(frame)
    }

    private func endLinkSetup() throws -> [UInt8] {
        try DataX.encode(channel: 0x8001, words: [Self.linkSetup], payload: Proto.field(1, 1) + Proto.field(2, bytes: Bytes.random(16)))
    }

    private func deviceInfoRequest() throws -> [UInt8] {
        try DataX.encode(channel: 0x8003, words: Self.serviceOpen, payload: Proto.field(1, 1) + Proto.field(3, bytes: []))
    }

    // MARK: feed

    public func feed(_ bytes: [UInt8], time: Double) throws -> FeedResult {
        lastClock = time
        pending += bytes
        var result = FeedResult()
        while receiver == nil, pending.count >= 4 {
            guard pending[0] & 0x80 != 0 else { throw perr("Unexpected bytes before band encryption") }
            let size = Int(Bytes.be16(pending, 0) & 0x7fff) + 4
            guard size >= 8 else { throw perr("Invalid band setup length") }
            guard pending.count >= size else { break }
            let frame = Array(pending.prefix(size))
            pending.removeFirst(size)
            let offset = frame[2] & 0x80 != 0 ? 8 : 4
            guard size >= offset + 4 else { throw perr("Truncated band setup header") }
            let kind = Bytes.be32(frame, offset)
            let fields = try ProtoFields(parsing: Array(frame[(offset + 4)...]))
            note(.info, "Handshake message 0x\(kind.hex8) on channel 0x\(String(Bytes.be16(frame, 2), radix: 16)), \(size)B: \(fields.shape())")
            let point = try fields.bytes(1, count: 64)
            guard let peer = try? P256.KeyAgreement.PublicKey(rawRepresentation: point) else {
                throw perr("Invalid band public key")
            }
            switch kind {
            case 0x0200_0001:
                let curve = try fields.integer(3)
                let parameters = try fields.integer(4)
                // A bitmask of the band's schemes. Older firmware offers exactly 3; newer offers 27 and uses 26.
                let newer = parameters & 24 != 0
                guard peerKey == nil, curve == 0, newer || parameters & 3 == 3 else {
                    throw perr("Unsupported band encryption parameters (repeated: \(peerKey != nil), curve \(curve), parameters \(parameters))")
                }
                peerChallenge = try fields.bytes(2, count: 16)
                peerKey = point
                guessing = newer
                variant = newer ? AirShieldVariant.scheme26Guesses[schemeGuess % AirShieldVariant.scheme26Guesses.count] : .scheme3
                note(.info, "Band RequestEncryption: offers parameters \(parameters) (\(newer ? "newer firmware" : "scheme 3")); announcing scheme \(variant.announce)\(newer ? ", key guess \(schemeGuess)" : "")")
                result.outgoing += try DataX.encode(channel: 1, words: [0x0200_0002],
                    payload: Proto.field(1, bytes: publicPoint) + Proto.field(2, bytes: seed) + Proto.field(3, bytes: iv)
                        + Proto.field(4, UInt64(base)) + Proto.field(5, variant.announce))
            case 0x0200_0002:
                let parameters = try fields.integer(5)
                guard let peerKey, let peerChallenge, peerKey == point else {
                    throw perr("Unexpected band encryption response (parameters \(parameters))")
                }
                peerParameters = parameters
                let shared = try secret.sharedSecretFromKeyAgreement(with: peer).withUnsafeBytes { Array($0) }
                let peerSeed = try fields.bytes(2, count: 32)
                let peerIV = try fields.bytes(3, count: 16)
                let counter = try fields.integer(4)
                guard counter <= UInt64(UInt32.max) else { throw perr("Invalid band packet counter") }
                transmitter = AirShieldCipher(keys: try .derive(variant, secret: shared, challenge: peerChallenge, seed: seed),
                                              iv: iv, counter: base)
                receiver = AirShieldReceiver(cipher: AirShieldCipher(
                    keys: try .derive(variant, secret: shared, challenge: challenge, seed: peerSeed), iv: peerIV, counter: UInt32(counter)))
                self.peerSeed = peerSeed
                note(.info, "Band EnableEncryption: band names scheme \(parameters); keys derived")
                if ceremony != nil {
                    setupStage = .ceremony
                    note(.notice, "Starting the ownership ceremony (identity read)")
                    result.outgoing += try encrypt(ceremony!.start())
                } else if enrollment != nil {
                    setupStage = .identity
                    note(.notice, "Sending EnableTrust signed with the stored owner key (\(enrollment!.fingerprint))")
                    result.outgoing += try encrypt(enableTrust(serviceAlreadyOpen: false))
                } else {
                    note(.notice, "No owner key: legacy startup (empty identity query + link setup)")
                    result.outgoing += try encrypt(DataX.encode(channel: 0x8002, words: [0x8100_0024, 0x0200_3000]))
                    result.outgoing += try encrypt(endLinkSetup())
                }
            default:
                throw perr("Unrecognized band setup message 0x\(kind.hex8)")
            }
        }
        guard receiver != nil else { return result }
        let records: [[UInt8]]
        do {
            records = try receiver!.feed(pending)
        } catch {
            if authenticatedPackets == 0, guessing {
                throw perr("\(error.localizedDescription) (the band chose encryption scheme \(peerParameters); key guess \(schemeGuess) was wrong)")
            }
            throw error
        }
        pending.removeAll()
        if receiver!.cipher.padsAligned { datax.setAlwaysPadded() }
        for plaintext in records {
            authenticatedPackets += 1
            if authenticatedPackets == 1 {
                note(.notice, "First encrypted packet authenticated\(guessing ? " — key guess \(schemeGuess) is correct" : "")")
            }
            let frames = try datax.feed(plaintext)
            if setupStage != .input && setupStage != .deviceInfo {
                note(.debug, "packet \(authenticatedPackets): \(plaintext.count)B plaintext; frames \(frames.map(\.summary)); \(datax.pendingCount)B held")
                for frame in frames {
                    let shape = (try? ProtoFields(parsing: frame.payload))?.shape() ?? "not protobuf"
                    note(.info, "setup frame \(frame.summary): \(shape)")
                    if dumpSetupPayloads, frame.words.last != 0x0200_2003 {
                        note(.debug, "setup frame payload hex (\(frame.payload.count)B): \(Array(frame.payload.prefix(160)).hex)\(frame.payload.count > 160 ? "…" : "")")
                    }
                }
            }
            for frame in frames {
                framesDecoded += 1
                if logFrames && setupStage == .input { note(.debug, "frame \(frame.summary)") }
                do {
                    result.events += try input(frame, time: time, outgoing: &result.outgoing)
                } catch BandError.protocolError(let message) where setupStage == .input && message.contains("protobuf") {
                    // A frame whose protobuf doesn't parse is dropped, not the connection: the record was authenticated.
                    decodeFailures += 1
                    note(.warning, "Skipped an undecodable frame (\(message)): \(frame.summary)")
                }
            }
            if streaming, !stopping, time - lastHeartbeat >= 0.2 {
                lastHeartbeat = time
                result.events.append(.heartbeat)
            }
        }
        return result
    }

    // MARK: periodic

    /// Call periodically (every ~50 ms): expires requests and releases the dial.
    public func tick(time: Double) -> [SessionEvent] {
        lastClock = time
        configurationRequests.removeAll { time >= $0.deadline }
        dial.tick(time)
        var events = engagementEvents()
        guard !stopping else { return events }
        if let request = handRequest, time >= request.deadline {
            handRequest = nil
            hand = nil
            events.append(.handednessFailure("Couldn't confirm the band hand. Reconnect and try again."))
        }
        if let request = batteryRequest, time >= request.deadline {
            batteryRequest = nil
            events.append(.batteryStatus(nil))
        }
        if let request = rawRequest, time >= request.deadline {
            rawRequest = nil
            events.append(.rawEmgFailure("The band didn't confirm the EMG change. Turn readings off, then try again."))
        }
        if let request = hapticsRequest, time >= request.deadline {
            hapticsRequest = nil
            events.append(.hapticsFinished(sequence: UInt32(truncatingIfNeeded: request.id), rpcSuccess: false, hapticsSuccess: nil))
        }
        return events
    }

    // MARK: requests

    /// Haptics wait for other requests to finish.
    public var hapticsReady: Bool {
        setupStage == .input && streamsEnabled && !stopping && handRequest == nil && rawRequest == nil
            && batteryRequest == nil && hapticsRequest == nil && configurationRequests.isEmpty && otaJob == nil
    }

    public func sendHaptics(_ command: HapticsCommand, time: Double) throws -> [UInt8] {
        guard hapticsReady else {
            throw BandError.busy("Wait for the band's control channel and outstanding requests before haptics.")
        }
        let id = configurationID + 1
        let frame = try DataX.encode(channel: Self.configurationChannel, payload: command.encodeRPC(sequence: UInt32(id)))
        let bytes = try encrypt(frame)
        configurationID = id
        hapticsRequest = (id, time + 5, command.responseField)
        return bytes
    }

    public func setRawEmgEnabled(_ enabled: Bool, time: Double) throws -> [UInt8] {
        guard !stopping else { throw BandError.busy("Wait for the band to reconnect before changing readings.") }
        guard rawRequest == nil else { throw BandError.busy("Wait for the current EMG change to finish.") }
        rawEmg = enabled
        guard streamsEnabled else { return [] }
        rawRequestID += 1
        let id = rawRequestID
        rawRequest = RawRequest(enabled: enabled, stage: enabled ? .config : .update, id: id, deadline: time + 8)
        if enabled {
            let words = configServiceOpened ? [] : Self.serviceOpen
            configServiceOpened = true
            note(.info, "EMG: reading the sensor configuration (request \(id))")
            return try encrypt(DataX.encode(channel: Self.configServiceChannel, words: words,
                                            payload: Proto.field(1, id) + Proto.field(5, bytes: [])))
        }
        return try rawStreamUpdate(id: id, enabled: false)
    }

    private func rawStreamUpdate(id: UInt64, enabled: Bool) throws -> [UInt8] {
        rawRequested = true
        let control = Proto.field(2, enabled ? 1 : 0) + Self.streamFields.flatMap { Proto.field($0, 1) } + captureStreamFields(nil)
        note(.info, "EMG: updating the subscription (raw \(enabled ? "on" : "off"), request \(id))")
        return try encrypt(DataX.encode(channel: Self.streamChannel, payload: Proto.field(1, id) + Proto.field(4, bytes: control)))
    }

    /// Write the band's hand setting, then confirm it with an independent read.
    public func setHandedness(_ hand: Hand, time: Double) throws -> [UInt8] {
        guard streamsEnabled, !stopping, self.hand != nil, handRequest == nil else {
            throw BandError.busy("Wait for the band to report its hand before changing it.")
        }
        dial = PinchDial()
        return try requestHand(hand, reading: false, time: time)
    }

    private func requestActive() throws -> [UInt8] {
        let frame = try DataX.encode(channel: Self.configurationChannel,
                                     payload: Proto.field(1, Self.activeRequest) + Proto.field(5, bytes: Proto.field(6, 2)))
        let bytes = try encrypt(frame)
        configurationRequests.append((Self.activeRequest, lastClock + 5))
        return bytes
    }

    private func requestHand(_ hand: Hand?, reading: Bool, time: Double) throws -> [UInt8] {
        let id = configurationID + 1
        // ConfigReq.is_left_handed is field 10. An empty ConfigReq reads current settings.
        let config = reading ? [] : Proto.field(10, hand == .left ? 1 : 0)
        let words = configurationID == 0 ? Self.serviceOpen : []
        let bytes = try encrypt(DataX.encode(channel: Self.configurationChannel, words: words,
                                             payload: Proto.field(1, id) + Proto.field(5, bytes: config)))
        configurationID = id
        handRequest = HandRequest(id: id, hand: hand, reading: reading, deadline: time + 5)
        return bytes
    }

    /// BatteryInfoReq: an empty read request, separate from sensor subscriptions.
    public func queryBatteryStatus(time: Double) throws -> [UInt8] {
        guard streamsEnabled, !stopping, !batteryUnavailable, batteryRequest == nil else { return [] }
        batteryRequestID += 1
        let id = batteryRequestID
        batteryRequest = (id, time + 3)
        let words = batteryChannelOpened ? [] : Self.serviceOpen
        batteryChannelOpened = true
        return try encrypt(DataX.encode(channel: Self.batteryChannel, words: words,
                                        payload: Proto.field(1, id) + Proto.field(2, bytes: [])))
    }

    /// Read the existing subscription's status when sensor traffic goes quiet.
    // MARK: handwriting (band model capture)

    public var handwritingStatus: ModelCaptureStatus { modelCapture.status }
    public var handwritingActive: Bool { modelCapture.status.active }

    /// Switches the band's handwriting model on (settings found by name, snapshotted, read back).
    public func startHandwriting(time: Double) throws {
        guard streamsEnabled, !stopping else { throw BandError.busy("Connect the band before starting handwriting.") }
        guard rawRequest == nil, !rawRequested || !rawEmg else { throw BandError.busy("Turn raw EMG off before handwriting.") }
        guard !probeFlags.values.contains(true) else { throw BandError.busy("Turn the experimental streams off before handwriting.") }
        guard !survey.running else { throw BandError.busy("Wait for the band survey to finish.") }
        guard otaJob == nil else { throw BandError.busy("A firmware update is running.") }
        try modelCapture.start(at: time)
    }

    /// Puts the band's settings back (verified by readback) and stops the model streams.
    public func stopHandwriting(time: Double) { modelCapture.restore(at: time) }

    /// After an interrupted capture (app killed, link lost): restore the band's normal settings.
    public func recoverHandwriting(time: Double) throws {
        guard streamsEnabled, !stopping else { throw BandError.busy("Connect the band first.") }
        try modelCapture.recoverNormalMode(at: time)
    }

    /// Sends the capture's next request when nothing else is in flight. Call from the periodic tick.
    public func flushModelCapture(time: Double) throws -> FeedResult {
        var result = FeedResult()
        if !stopping, rawRequest == nil, otaJob == nil, !modelCapture.status.active, let request = survey.next(at: time) {
            let opened: Bool
            switch request.channel {
            case Self.configServiceChannel: opened = configServiceOpened; configServiceOpened = true
            case Self.configurationChannel: opened = configurationID != 0
            default: opened = settingsOpened; settingsOpened = true
            }
            result.outgoing += try encrypt(DataX.encode(channel: request.channel, words: opened ? [] : Self.serviceOpen,
                                                        payload: survey.payload(for: request)))
        }
        for line in survey.drainNotes() { note(.info, "Survey: \(line)") }
        result.events += survey.drainEvents()
        if !stopping, rawRequest == nil, otaJob == nil, let request = modelCapture.next(at: time) {
            let opened: Bool
            switch request.channel {
            case Self.streamChannel: opened = true
            case Self.configServiceChannel: opened = configServiceOpened; configServiceOpened = true
            default: opened = settingsOpened; settingsOpened = true
            }
            let streamControl = [UInt32(3), 6, 8].flatMap { Proto.field($0, 1) } + captureStreamFields(nil)
            result.outgoing += try encrypt(DataX.encode(channel: request.channel, words: opened ? [] : Self.serviceOpen,
                                                        payload: modelCapture.payload(for: request, streamControl: streamControl)))
        }
        for line in modelCapture.drainNotes() { note(.info, "Handwriting: \(line)") }
        result.events += modelCapture.drainEvents()
        return result
    }

    /// Stream fields beyond 3/6/8: 4/22/23 once the capture has touched them (so no request leaves them
    /// to the band's default), and the experimental flags while no capture runs. Forced off
    /// (`forced = false`) when stopping.
    private func captureStreamFields(_ forced: Bool?) -> [UInt8] {
        var flags: [UInt32: Bool] = [:]
        if modelCapture.streamTouched { for field in [UInt32(4), 22, 23] { flags[field] = modelCapture.streamWanted } }
        if !modelCapture.status.active { flags.merge(probeFlags) { $1 } }
        if forced == false { for field in flags.keys { flags[field] = false } }
        return flags.keys.sorted().flatMap { Proto.field($0, flags[$0]! ? 1 : 0) }
    }

    // MARK: firmware update

    public var otaRunning: Bool { otaJob != nil }
    /// Whether stopping now is safe: no update running, or one that hasn't sent Commit.
    public var otaCancellable: Bool { otaJob?.cancellable ?? true }

    /// Runs one firmware update step (see `OtaMode`). Returns the first bytes to write; progress
    /// arrives as `.otaProgress` events, from `feed` and from `otaTick`.
    public func otaStart(_ plan: OtaPlan, time: Double) throws -> FeedResult {
        guard streamsEnabled, !stopping, handRequest == nil, rawRequest == nil else { throw BandError.busy("Wait for the band to finish connecting.") }
        guard hapticsRequest == nil else { throw BandError.busy("Wait for the vibration to finish.") }
        guard !modelCapture.status.active, !survey.running else { throw BandError.busy("Stop handwriting and the survey first.") }
        guard !probeFlags.values.contains(true) else { throw BandError.busy("Turn the experimental streams off first.") }
        guard !rawRequested || !rawEmg else { throw BandError.busy("Turn raw EMG off first.") }
        if let job = otaJob {
            // Cancel stops a running update (before its Commit), then aborts what the band holds.
            guard plan.mode == .cancel, job.mode != .cancel else { throw BandError.busy("An update is already running.") }
            guard job.cancellable else { throw BandError.busy("The band is installing: it isn't safe to cancel now.") }
            otaJob = nil
            note(.notice, "Firmware: stopping the update")
        }
        let job = OtaJob(plan: plan)
        var ids = configurationID
        let bodies = job.begin(ids: &ids, now: time)
        var result = FeedResult()
        result.outgoing = try otaFrames(bodies, ids: ids) + setOtaQuiet(true)
        otaJob = job
        result.events = [otaEvent(job)]
        return result
    }

    /// Resends late chunks and gives up on silent requests. Call from the periodic tick.
    public func otaTick(time: Double) throws -> FeedResult {
        var result = FeedResult()
        guard let job = otaJob, !stopping else { return result }
        var ids = configurationID
        let bodies = job.tick(ids: &ids, now: time)
        result.outgoing = try otaFrames(bodies, ids: ids)
        if job.done || !bodies.isEmpty { result.events = [otaEvent(job)] }
        if job.done {
            otaJob = nil
            result.outgoing += try setOtaQuiet(false)
        }
        return result
    }

    private func receiveOta(_ job: OtaJob, fields: ProtoFields, time: Double, outgoing: inout [UInt8]) throws -> [SessionEvent] {
        var ids = configurationID
        let bodies = job.receive(fields, ids: &ids, now: time)
        if let status = job.lastStatus { otaLast = status }
        outgoing += try otaFrames(bodies, ids: ids)
        let event = otaEvent(job)
        if job.done {
            otaJob = nil
            outgoing += try setOtaQuiet(false)
        }
        return [event]
    }

    private func otaEvent(_ job: OtaJob) -> SessionEvent {
        let lines = job.takeLog()
        for line in lines { note(line.hasPrefix("FAILED") || line.hasPrefix("COMMITTED") ? .notice : .info, "Firmware: \(line)") }
        return .otaProgress(OtaReport(mode: job.mode, version: job.version, running: !job.done, lines: lines, items: job.progress,
                                      status: job.lastStatus, committed: job.committed, commitAccepted: job.commitAccepted,
                                      cancellable: job.cancellable))
    }

    private func setOtaQuiet(_ quiet: Bool) throws -> [UInt8] {
        guard otaQuiet != quiet else { return [] }
        otaQuiet = quiet
        return try streamRequest(id: 3, enabled: true)
    }

    /// Frame and encrypt update requests on the configuration service; `ids` is the counter after them.
    private func otaFrames(_ bodies: [[UInt8]], ids: UInt64) throws -> [UInt8] {
        var out: [UInt8] = []
        for body in bodies {
            let words = configurationID == 0 ? Self.serviceOpen : []
            out += try encrypt(DataX.encode(channel: Self.configurationChannel, words: words, payload: body))
            configurationID = max(configurationID, 1)
        }
        configurationID = max(configurationID, ids)
        return out
    }

    // MARK: exploring (read-only survey, experimental streams)

    public var surveyReport: BandSurveyReport { survey.report }
    public var surveyRunning: Bool { survey.running }

    /// Reads every band setting (count, describe, read), the whole config and the update status.
    /// Only read requests are sent; requests go out from `flushModelCapture`.
    public func startSurvey(time: Double, updateStatusOnly: Bool = false) throws {
        guard streamsEnabled, !stopping else { throw BandError.busy("Connect the band first.") }
        guard !modelCapture.status.active else { throw BandError.busy("Stop handwriting before the survey.") }
        guard otaJob == nil else { throw BandError.busy("A firmware update is running.") }
        survey.start(at: time, updateStatusOnly: updateStatusOnly)
    }

    /// Stream flags the explorer may toggle. 2 (raw EMG) and 3/6/8 (gestures, gyro, orientation)
    /// belong to the session; turning those off is the band's power saving and ends the session.
    public static func probeable(_ field: UInt32) -> Bool { (1...64).contains(field) && ![2, 3, 6, 8].contains(field) }

    /// Turns experimental stream flags on (the rest of the ones touched so far off). Streams aren't
    /// persisted by the band; disconnecting (or this with an empty set) turns them off.
    public func setProbeStreams(_ fields: Set<UInt32>, time: Double) throws -> [UInt8] {
        guard streamsEnabled, !stopping, rawRequest == nil else { throw BandError.busy("Connect the band first.") }
        guard !modelCapture.status.active else { throw BandError.busy("Stop handwriting first.") }
        guard otaJob == nil else { throw BandError.busy("A firmware update is running.") }
        for field in fields where !Self.probeable(field) { throw perr("Stream flag \(field) is managed by the app") }
        for field in Set(probeFlags.keys).union(fields) { probeFlags[field] = fields.contains(field) }
        probeRequestID += 1
        let control = Self.streamFields.flatMap { Proto.field($0, 1) } + captureStreamFields(nil)
        note(.notice, "Experimental streams: \(probeFlags.keys.sorted().map { "\($0)=\(probeFlags[$0]! ? 1 : 0)" }.joined(separator: " "))")
        return try encrypt(DataX.encode(channel: Self.streamChannel, payload: Proto.field(1, probeRequestID) + Proto.field(4, bytes: control)))
    }

    public func queryStreamState() throws -> [UInt8] {
        guard streamsEnabled, !stopping, rawRequest == nil else { return [] }
        return try streamRequest(id: 5, enabled: nil)
    }

    /// Disable the streams. An empty return means close now; otherwise write and wait ≤ 3 s for `stopAcknowledged`.
    public func stop() throws -> [UInt8] {
        guard !stopping else { return [] }
        stopping = true
        handRequest = nil
        rawRequest = nil
        batteryRequest = nil
        guard transmitter != nil, setupStage == .input else { return [] }
        return try streamRequest(id: 4, enabled: false)
    }

    public func ceremonyPairRequestCompleted(signature: [UInt8], receipt: String) throws -> [UInt8] {
        guard !stopping else { return [] }
        guard ceremony != nil else { throw perr("No enrollment is running") }
        return try encrypt(ceremony!.pairRequestCompleted(signature: signature, receipt: receipt))
    }

    /// Persist `pendingIdentity` as tentative BEFORE writing these bytes: the band may commit
    /// ownership even if its confirmation never arrives.
    public func ceremonyPairCompleted(signature: [UInt8], receipt: String, devicePublicKey: [UInt8]?) throws -> [UInt8] {
        guard !stopping else { return [] }
        guard ceremony != nil else { throw perr("No enrollment is running") }
        return try encrypt(ceremony!.pairCompleted(signature: signature, receipt: receipt, devicePublicKey: devicePublicKey))
    }

    private func enableTrust(serviceAlreadyOpen: Bool) throws -> [UInt8] {
        guard let identity = enrollment else { throw perr("No owner identity is stored") }
        guard let peerKey, let peerChallenge else { throw perr("Band encryption is not ready") }
        let digest = trustDigest(challenge: peerChallenge, receiver: peerKey, seed: seed, sender: publicPoint)
        let signature = try identity.sign(digest)
        let words: [UInt32] = serviceAlreadyOpen ? [0x0200_1000] : [0x8100_0024, 0x0200_1000]
        return try DataX.encode(channel: 0x8002, words: words,
                                payload: Proto.field(1, bytes: Array(SHA256.hash(data: identity.appPoint))) + Proto.field(2, bytes: signature))
    }

    private func streamRequest(id: UInt64, enabled: Bool?) throws -> [UInt8] {
        var selected = Self.streamFields
        if enabled == false, rawRequested { selected.insert(2, at: 0) }
        let quiet = otaQuiet
        let control: [UInt8] = enabled.map { on in
            selected.flatMap { Proto.field($0, on && !(quiet && [6, 8].contains($0)) ? 1 : 0) } + captureStreamFields(on ? nil : false)
        } ?? []
        let words = id == 2 ? Self.serviceOpen : []
        return try encrypt(DataX.encode(channel: Self.streamChannel, words: words,
                                        payload: Proto.field(1, id) + Proto.field(4, bytes: control)))
    }

    private func engagementEvents() -> [SessionEvent] {
        guard dial.engaged != emittedEngagement else { return [] }
        emittedEngagement = dial.engaged
        dialPending = 0
        lastDial = -.infinity
        return [.dialState(emittedEngagement)]
    }

    // MARK: input

    private func link(accepted fields: ProtoFields) throws -> Bool {
        switch try fields.integer(1) {
        case 0: throw perr(Self.bandBusy)
        case let status: return status == 1
        }
    }

    private func input(_ frame: DataXFrame, time: Double, outgoing: inout [UInt8]) throws -> [SessionEvent] {
        if let kind = frame.words.last {
            guard channelTypes.count < 1024 || channelTypes[frame.channel] != nil else { throw perr("Too many band input channels") }
            channelTypes[frame.channel] = kind
        }
        guard let kind = channelTypes[frame.channel] else { return [] }
        kindCounts[kind, default: 0] += 1
        let route = Self.route(frame.channel)
        if setupStage == .input, !stopping {
            // The band names a channel's kind only when it changes, and it sends firmware logs and error
            // words on the channels it answers on: an unnamed frame after one of those can still be an
            // answer. The survey and the capture match it by request id, so offer them every unnamed frame.
            let mayAnswer = kind == Self.rpcResponse || frame.words.isEmpty
            if mayAnswer, survey.receive(channel: frame.channel, payload: frame.payload, at: time) {
                for line in survey.drainNotes() { note(.info, "Survey: \(line)") }
                return survey.drainEvents()
            }
            if mayAnswer, modelCapture.receive(channel: frame.channel, payload: frame.payload, at: time) {
                for line in modelCapture.drainNotes() { note(.info, "Handwriting: \(line)") }
                return modelCapture.drainEvents()
            }
            if let word = frame.words.last, word & 0xff00_0000 == 0x0300_0000 {
                note(.warning, "Band sent error word 0x\(String(word, radix: 16)) on 0x\(String(frame.channel, radix: 16))")
                if modelCapture.rejected(channel: frame.channel, word: word, at: time) {
                    for line in modelCapture.drainNotes() { note(.info, "Handwriting: \(line)") }
                    return modelCapture.drainEvents()
                }
            }
            if kind == Self.firmwareLogKind {
                let fields = try? ProtoFields(parsing: frame.payload)
                let text = (try? fields.flatMap { try ProtoFields(parsing: $0.bytes(3)) })??.text(1) ?? fields?.readable() ?? "\(frame.payload.count)B"
                return [.firmwareLog(text)]
            }
            if kind == Self.rawInferenceKind {
                // A malformed frame is skipped: failing here would leave the band in the capture's mode.
                guard modelCapture.status.active || probeFlags[4] == true, let sample = try? InferenceSample(payload: frame.payload) else {
                    unknownKinds[kind, default: 0] += 1
                    return modelCapture.drainEvents()
                }
                if modelCapture.status.active { modelCapture.receive(sample, at: time) }
                for line in modelCapture.drainNotes() { note(.info, "Handwriting: \(line)") }
                return [.inferenceSample(sample)] + modelCapture.drainEvents()
            }
        }
        // Older (scheme-3) firmware sends its EnableTrustEC proof as soon as the identity service opens,
        // before answering the identity read. Acknowledge it as the trust flow does, then carry on.
        if (setupStage == .ceremony || setupStage == .link), !stopping, frame.words.last == 0x0200_1001, route & 0x8000 != 0 {
            if earlyProofAcknowledged { note(.warning, "Band repeated its early trust proof; acknowledging again") }
            earlyProofAcknowledged = true
            note(.notice, "Band sent its trust proof before the \(setupStage == .ceremony ? "identity read" : "link setup") (older firmware); acknowledging it on 0x\(String(frame.channel & 0x7fff, radix: 16)) and continuing")
            outgoing += try encrypt(DataX.encode(channel: frame.channel & 0x7fff, words: [0x0300_1000]))
            return []
        }
        if ceremony != nil, setupStage == .ceremony, !stopping { return try receiveCeremony(frame, outgoing: &outgoing) }
        if enrollment != nil, setupStage == .identity, !stopping { return try receiveIdentity(frame, outgoing: &outgoing) }
        if kind == Self.linkSetup, route == 0x8001, setupStage == .link, !stopping {
            guard try link(accepted: ProtoFields(parsing: frame.payload)) else {
                throw perr("The band couldn't finish setting up the connection. Try reconnecting.")
            }
            note(.info, "Link setup accepted (legacy); requesting device info")
            setupStage = .deviceInfo
            outgoing += try encrypt(deviceInfoRequest())
            return []
        }
        if route & 0x7fff == Self.batteryChannel & 0x7fff, !stopping {
            if kind == Self.serviceRejected {
                batteryRequest = nil
                batteryUnavailable = true
                note(.info, "The band rejected the battery status service")
                return [.batteryStatus(nil)]
            }
            if kind == Self.rpcResponse, let request = batteryRequest {
                guard (try? ProtoFields(parsing: frame.payload).requiredInteger(1)) == request.id else { return [] }
                batteryRequest = nil
                return [.batteryStatus(try? BatteryStatus.parse(response: frame.payload))]
            }
            return []
        }
        if kind == Self.serviceRejected, !stopping {
            note(.warning, "Service rejected on \(frame.summary) during \(setupStage.rawValue)")
            if route == 3, setupStage == .deviceInfo { throw perr("The band rejected gesture setup. Try reconnecting.") }
            if let raw = rawRequest, route == 7 || (route == 5 && raw.stage != .config) {
                rawRequest = nil
                return [.rawEmgFailure("The band rejected the EMG request.")]
            }
            if route == 5, setupStage == .input { throw perr("The band rejected the input subscription. Try reconnecting.") }
            if route == 6, handRequest != nil {
                handRequest = nil
                hand = nil
                return [.handednessFailure("The band couldn't report its hand setting. Reconnect and try again.")]
            }
            return []
        }
        guard [Self.rpcResponse, Self.rawEmgKind, Self.gestureKind, Self.gyroKind, Self.orientationKind].contains(kind) else {
            unknownKinds[kind, default: 0] += 1
            if unknownKinds[kind] == 1 || unknownKinds[kind]! % 50 == 0 {
                unknownShapes[kind] = "\(frame.payload.count)B on 0x\(String(frame.channel, radix: 16)): " + ((try? ProtoFields(parsing: frame.payload))?.shape(depth: 2) ?? "not protobuf")
            }
            if unknownKinds[kind] == 1 || unknownKinds[kind]! % 500 == 0 {
                let shape = (try? ProtoFields(parsing: frame.payload))?.shape(depth: 1) ?? "not protobuf"
                note(.info, "Unhandled message kind 0x\(kind.hex8) #\(unknownKinds[kind]!) (\(frame.summary)): \(shape)")
            }
            return []
        }
        if kind == Self.rpcResponse, route == 3, setupStage == .deviceInfo, !stopping {
            let fields = try ProtoFields(parsing: frame.payload)
            var events: [SessionEvent] = []
            if let info = DeviceInfo.find(fields) {
                deviceInfo = info
                note(.notice, "Device info: firmware \(info.firmware), hardware \(info.hardware), model \(info.model)")
                events.append(.deviceInfo(info))
            }
            guard try fields.requiredInteger(1) == 1 else { return events }
            guard try fields.requiredInteger(2) == 1 else { throw perr("The band rejected gesture setup. Try reconnecting.") }
            setupStage = .input
            note(.notice, "Subscribing to gestures, gyro and orientation (stream flags 3, 6, 8); reading hand; requesting active state")
            outgoing += try streamRequest(id: 2, enabled: nil)
            outgoing += try streamRequest(id: 3, enabled: true)
            outgoing += try requestHand(nil, reading: true, time: time)
            outgoing += try requestActive()
            return events
        }
        guard setupStage == .input else { return [] }
        if kind == Self.rpcResponse, route & 0x7fff == Self.configurationChannel & 0x7fff {
            guard !stopping else { return [] }
            let fields = try ProtoFields(parsing: frame.payload)
            note(.debug, "Config RPC response: \(fields.shape(depth: 1))")
            if let id = try? fields.integer(1), let index = configurationRequests.firstIndex(where: { $0.id == id }) {
                configurationRequests.remove(at: index)
                if id == Self.activeRequest { note(.info, "Band acknowledged the active-state request (status \((try? fields.integer(2)) ?? 0))") }
            }
            if let request = hapticsRequest, (try? fields.integer(1)) == request.id {
                hapticsRequest = nil
                let rpcSuccess = (try? fields.integer(2)) == 1
                var hapticsSuccess: Bool?
                if let bytes = try? fields.bytes(18), let response = try? ProtoFields(parsing: bytes),
                   (try? response.bytes(request.field)) != nil, response.contains(1) {
                    hapticsSuccess = (try? response.integer(1)) == 0
                }
                return [.hapticsFinished(sequence: UInt32(truncatingIfNeeded: request.id), rpcSuccess: rpcSuccess, hapticsSuccess: hapticsSuccess)]
            }
            if let job = otaJob, let seq = fields.optionalInteger(1), job.owns(seq) {
                return try receiveOta(job, fields: fields, time: time, outgoing: &outgoing)
            }
            return try receiveHand(fields, time: time, outgoing: &outgoing)
        }
        if kind == Self.rpcResponse, !stopping, let raw = rawRequest, let events = try receiveRaw(frame, pending: raw, outgoing: &outgoing) {
            return events
        }
        if kind == Self.rpcResponse, route != Self.streamChannel & 0x7fff { return [] }
        if kind == Self.rpcResponse {
            let fields = try ProtoFields(parsing: frame.payload)
            let request = try fields.integer(1)
            if request > 0x3000_0000, request <= probeRequestID {
                guard let bytes = try? fields.bytes(5), let flags = try? ProtoFields(parsing: bytes) else {
                    note(.warning, "Experimental stream change: band answered \(fields.shape(depth: 1))")
                    return [.probeStreams([:])]
                }
                let reported = Dictionary(uniqueKeysWithValues: flags.fieldNumbers.compactMap { field in flags.optionalInteger(field).map { (field, $0) } })
                note(.info, "Experimental stream change acknowledged (status \((try? fields.integer(2)) ?? 0)): \(flags.shape(depth: 0))")
                return [.probeStreams(reported)]
            }
            if request == 3 || request == 5 {
                guard !stopping else { return [] }
                guard try fields.integer(2) == 1 else { throw perr("The band rejected the input subscription") }
                let flags = try ProtoFields(parsing: try fields.bytes(5))
                let required: [UInt32] = otaQuiet ? [3] : Self.streamFields
                streamsEnabled = try required.allSatisfy { field in try flags.contains(field) && flags.integer(field) == 1 }
                guard streamsEnabled else { throw perr("The band input subscription stopped") }
                var events: [SessionEvent] = []
                if request == 3, rawEmg, rawRequest == nil { outgoing += try setRawEmgEnabled(true, time: time) }
                if !streaming {
                    streaming = true
                    note(.notice, "Band acknowledged the input subscription — streaming")
                    events.append(.connected)
                }
                return events
            } else if request == 4, try fields.integer(2) == 1, fields.contains(5) {
                let flags = try ProtoFields(parsing: try fields.bytes(5))
                var expected = Self.streamFields
                if rawRequested { expected.insert(2, at: 0) }
                stopAcknowledged = try expected.allSatisfy { field in try flags.contains(field) && flags.integer(field) == 0 }
                note(.info, "Stop acknowledged: \(stopAcknowledged)")
            }
            return []
        }
        guard !stopping else { return [] }
        if kind == Self.rawEmgKind {
            rawEmgFrames += 1
            rawEmgBytes += frame.payload.count
            var events: [SessionEvent] = []
            if !streaming {
                streaming = true
                lastHeartbeat = time
                events += [.connected, .heartbeat]
            }
            if rawEmgFrames == 1 { note(.notice, "First raw EMG payload received (\(frame.payload.count)B)") }
            return events + [.rawEmgFrame(frame.payload), .dataSeen]
        }
        let fields = try ProtoFields(parsing: frame.payload)
        let sequence = try fields.requiredInteger(1)
        let timestamp = try fields.requiredInteger(2)
        var events: [SessionEvent] = []
        if kind == Self.gestureKind {
            gestureMessages += 1
            let gesture = GestureMessage(sequence: sequence, timestampMicros: timestamp,
                                         finger: GestureMessage.name(GestureMessage.fingers, try fields.integer(3)),
                                         action: GestureMessage.name(GestureMessage.actions, try fields.integer(4)),
                                         derivedAction: GestureMessage.name(GestureMessage.derived, try fields.integer(5)),
                                         synthetic: try fields.integer(12) != 0, receivedAt: time)
            dial.gesture(gesture, now: time)
            events.append(.gesture(gesture))
            events += engagementEvents()
        } else {
            let bytes = try fields.bytes(3, count: kind == Self.gyroKind ? 6 : 16)
            motionMessages += 1
            if !streaming {
                streaming = true
                lastHeartbeat = time
                events += [.connected, .heartbeat]
            }
            if kind == Self.gyroKind {
                func axis(_ i: Int) -> Double { Double(Int16(bitPattern: UInt16(bytes[i * 2]) | UInt16(bytes[i * 2 + 1]) << 8)) }
                let values = SIMD3(axis(0), axis(1), axis(2))
                events.append(.motion(timestampMicros: timestamp, gyro: values))
                let delta = dial.gyro(timestamp: timestamp, values: values, now: time)
                events += engagementEvents()
                if let delta {
                    dialPending += delta
                    if time - lastDial >= 0.02 {
                        events.append(.dialTurn(dialPending))
                        lastDial = time
                        dialPending = 0
                    }
                }
            } else {
                func float(_ i: Int) -> Float {
                    Float(bitPattern: UInt32(bytes[i * 4]) | UInt32(bytes[i * 4 + 1]) << 8 | UInt32(bytes[i * 4 + 2]) << 16 | UInt32(bytes[i * 4 + 3]) << 24)
                }
                let q = SIMD4(float(0), float(1), float(2), float(3))
                let norm = (q * q).sum()
                if q.x.isFinite && q.y.isFinite && q.z.isFinite && q.w.isFinite && (0.9...1.1).contains(norm) {
                    orientationMessages += 1
                    events.append(.orientation(q))
                } else {
                    // band-core treats this as fatal; here it's counted and dropped so a glitch doesn't drop the link.
                    decodeFailures += 1
                    note(.warning, "Dropped an orientation sample that isn't a unit quaternion")
                }
            }
        }
        events.append(.dataSeen)
        return events
    }

    private func receiveHand(_ fields: ProtoFields, time: Double, outgoing: inout [UInt8]) throws -> [SessionEvent] {
        guard let request = handRequest, try fields.integer(1) == request.id else { return [] }
        handRequest = nil
        let failure = { (message: String) -> [SessionEvent] in [.handednessFailure(message)] }
        if time >= request.deadline {
            hand = nil
            return failure("Couldn't confirm the band hand. Reconnect and try again.")
        }
        guard try fields.integer(2) == 1 else {
            hand = nil
            return failure("The band couldn't apply its hand setting. Reconnect and try again.")
        }
        if !request.reading {
            outgoing += try requestHand(request.hand, reading: true, time: time)
            return []
        }
        guard fields.contains(6) else {
            hand = nil
            return failure("This band didn't report its hand setting.")
        }
        let config = try ProtoFields(parsing: try fields.bytes(6))
        guard config.contains(10), try config.integer(10) <= 1 else {
            hand = nil
            return failure("This band didn't report its hand setting.")
        }
        let reported: Hand = try config.integer(10) == 1 ? .left : .right
        hand = reported
        note(.info, "Band reports it is worn on the \(reported.rawValue) hand")
        var events: [SessionEvent] = [.handedness(reported)]
        if let expected = request.hand, expected != reported {
            events.append(.handednessFailure("The band didn't keep the selected hand. Reconnect and try again."))
        }
        return events
    }

    private func receiveRaw(_ frame: DataXFrame, pending raw: RawRequest, outgoing: inout [UInt8]) throws -> [SessionEvent]? {
        let fields = try ProtoFields(parsing: frame.payload)
        let expected = raw.stage == .config ? Self.configServiceChannel : Self.streamChannel
        guard Self.route(frame.channel) & 0x7fff == expected & 0x7fff, try fields.integer(1) == raw.id else { return nil }
        guard try fields.integer(2) == 1 else {
            rawRequest = nil
            return [.rawEmgFailure("The band rejected the EMG change. Gestures remain requested.")]
        }
        switch raw.stage {
        case .config:
            guard let config = try? EmgConfig.parse(response: frame.payload) else {
                rawRequest = nil
                return [.rawEmgFailure("The band didn't provide a readable EMG configuration.")]
            }
            note(.info, "EMG configuration: \(config.channels) channels @ \(config.sampleRate) Hz, \(config.adcBits)-bit, \(config.samplesPerBatch)/batch, encoding \(config.encoding)")
            rawRequestID += 1
            rawRequest = RawRequest(enabled: raw.enabled, stage: .query, id: rawRequestID, deadline: raw.deadline)
            outgoing += try streamRequest(id: rawRequestID, enabled: nil)
            return [.rawEmgConfiguration(config)]
        case .query:
            rawRequestID += 1
            rawRequest = RawRequest(enabled: raw.enabled, stage: .update, id: rawRequestID, deadline: raw.deadline)
            outgoing += try rawStreamUpdate(id: rawRequestID, enabled: raw.enabled)
            return []
        case .update:
            rawRequest = nil
            let flags = try ProtoFields(parsing: try fields.bytes(5))
            for field in Self.streamFields where try flags.integer(field) != 1 {
                throw perr("The band stopped gesture streams during the EMG change. Reconnect with readings off.")
            }
            guard try flags.integer(2) == (raw.enabled ? 1 : 0) else {
                return [.rawEmgFailure("The band didn't accept EMG alongside gestures.")]
            }
            return [.rawEmgState(raw.enabled)]
        }
    }

    private func receiveCeremony(_ frame: DataXFrame, outgoing: inout [UInt8]) throws -> [SessionEvent] {
        guard let kind = frame.words.last else { return [] }
        if kind & 0xff00_0000 == 0x0300_0000 {
            let code = kind & 0x00ff_ffff
            note(.warning, "Ownership ceremony result code 0x\(String(code, radix: 16)) on \(frame.summary)")
            throw BandError.ownershipRejected(code: code, message: Ceremony.failureMessage(code))
        }
        switch kind {
        case 0x0200_3001:
            let next = try ceremony!.identityRead(frame.payload)
            note(.info, "Ceremony: band identity read (certificate \(ceremony!.identity?.deviceCertificate.count ?? 0)B)")
            outgoing += try encrypt(next)
            return [.ceremonyStage("Reading the band identity")]
        case 0x0200_2001:
            let request = try ceremony!.skipChallenge(frame.payload)
            note(.info, "Ceremony: ownership nonce received; asking Meta to approve the claim")
            return [.ceremonyStage("Asking Meta to approve the claim"), .ceremonyHttp(.pairRequest(request))]
        case 0x0200_2003:
            let pair = try ceremony!.startChangeOwner(frame.payload)
            note(.info, "Ceremony: band returned its pending receipt (\(pair.receipt.count) chars); confirming with Meta")
            return [.ceremonyStage("Confirming the claim with Meta"), .ceremonyHttp(.pair(pair))]
        case 0x0200_2005:
            let identity = try ceremony!.complete(words: frame.words, payload: frame.payload)
            note(.notice, "Ceremony: the band committed the new owner key (\(identity.fingerprint)); establishing trust")
            enrollment = identity
            appTrusted = false
            bandTrusted = false
            endLinkSent = false
            setupStage = .identity
            outgoing += try encrypt(enableTrust(serviceAlreadyOpen: true))
            return [.ceremonyCompleted(identity), .ceremonyStage("Establishing trust")]
        default:
            note(.info, "Unhandled ceremony frame: \(frame.summary)")
            return []
        }
    }

    private func receiveIdentity(_ frame: DataXFrame, outgoing: inout [UInt8]) throws -> [SessionEvent] {
        guard let kind = frame.words.last else { return [] }
        let route = Self.route(frame.channel)
        var events: [SessionEvent] = []
        if kind & 0xff00_0000 == 0x0300_0000, route == 2 {
            guard kind == 0x0300_1000 else {
                let code = kind & 0x00ff_ffff
                note(.warning, "The band rejected the owner key: result 0x\(String(code, radix: 16))")
                if code == 0x1043 {
                    throw BandError.identityMismatch(code: code, message: "The band is enrolled to a different owner key. Import the right key, or claim the band again.")
                }
                throw BandError.identityMismatch(code: code, message: "The band rejected the stored owner key (\(Ceremony.failureMessage(code))). Try reconnecting.")
            }
            note(.info, "Band accepted our owner proof")
            appTrusted = true
        } else if kind == 0x0200_1001, route & 0x8000 != 0 {
            guard !bandTrusted else { throw perr("The band sent a duplicate identity proof") }
            let fields = try ProtoFields(parsing: frame.payload)
            guard let peerKey, let peerSeed else { throw perr("Band encryption is not ready") }
            let signature = try fields.bytes(2, count: 64)
            if let bandKey = enrollment?.bandPublicKey {
                let digest = trustDigest(challenge: challenge, receiver: publicPoint, seed: peerSeed, sender: peerKey)
                guard let proof = try? P256.Signing.ECDSASignature(rawRepresentation: signature),
                      bandKey.isValidSignature(proof, for: digest) else {
                    throw perr("The band's identity proof didn't verify against the stored band key. Try reconnecting.")
                }
                note(.info, "Band's identity proof verified against the stored band key")
            } else {
                note(.info, "Band sent its identity proof (no band key stored, so it isn't verified)")
            }
            bandTrusted = true
            outgoing += try encrypt(DataX.encode(channel: frame.channel & 0x7fff, words: [0x0300_1000]))
        } else if kind == Self.linkSetup, route == 0x8001, endLinkSent {
            let fields = try ProtoFields(parsing: frame.payload)
            guard try link(accepted: fields), try fields.bytes(2).count == 16 else {
                throw perr("Unexpected band link setup response")
            }
            note(.notice, "Link setup accepted; requesting device info")
            setupStage = .deviceInfo
            outgoing += try encrypt(deviceInfoRequest())
            return []
        } else {
            return []
        }
        if appTrusted, bandTrusted, !endLinkSent {
            endLinkSent = true
            events.append(.ownerTrusted(bandVerified: bandVerified))
            outgoing += try encrypt(endLinkSetup())
        }
        return events
    }
}
