import Foundation

/// One `RawInferenceSample` (kind 0x0200020c): the band's on-device model output.
/// In handwriting mode (pipeline 3) it is 100 log-probabilities, one per symbol (see `Handwriting`).
public struct InferenceSample: Sendable {
    public let sequence: UInt64
    public let timestampMicros: UInt64
    public let pipeline: UInt64
    public let latencyMicros: UInt64?
    public let values: [Float]

    init(payload: [UInt8]) throws {
        let fields = try ProtoFields(parsing: payload)
        sequence = try fields.requiredInteger(1)
        timestampMicros = try fields.requiredInteger(2)
        pipeline = try fields.requiredInteger(10)
        latencyMicros = fields.contains(7) ? try fields.integer(7) : nil
        let bytes = try fields.bytes(3)
        guard !bytes.isEmpty, bytes.count.isMultiple(of: 4), bytes.count <= 4096 else { throw perr("Invalid inference sample dimensions") }
        var values: [Float] = []
        values.reserveCapacity(bytes.count / 4)
        for index in stride(from: 0, to: bytes.count, by: 4) {
            values.append(Float(bitPattern: UInt32(bytes[index]) | UInt32(bytes[index + 1]) << 8
                                | UInt32(bytes[index + 2]) << 16 | UInt32(bytes[index + 3]) << 24))
        }
        guard values.allSatisfy(\.isFinite) else { throw perr("Nonfinite inference sample") }
        self.values = values
    }

    /// Pipeline 3 with 100 log-probabilities summing to 1: the handwriting model's text output.
    public var isTextDistribution: Bool {
        pipeline == 3 && values.count == 100 && values.allSatisfy { $0 <= 0.000001 }
            && abs(values.reduce(0.0) { $0 + exp(Double($1)) } - 1) < 0.001
    }
}

public struct ModelCaptureStatus: Equatable, Sendable {
    public enum Phase: Sendable { case idle, preparing, ready, restoring, finished }
    public let phase: Phase
    public let message: String
    public let problem: String?
    public let restorationVerified: Bool

    public init(phase: Phase, message: String, problem: String?, restorationVerified: Bool) {
        self.phase = phase
        self.message = message
        self.problem = problem
        self.restorationVerified = restorationVerified
    }

    public var active: Bool { phase == .preparing || phase == .ready || phase == .restoring }
    public static let idle = ModelCaptureStatus(phase: .idle, message: "", problem: nil, restorationVerified: false)
}

/// Switches the band's built-in handwriting model on for a while and puts the band back afterwards.
/// A port of kinesis `BandModelCapture.swift` (MIT) with rokid-lumen's name lookup (band-core
/// `model_capture.rs`): the model runs while `data-collection` is on and `data-collection-model` is 5.
/// Their ids differ between firmwares (27/28 on older bands, elsewhere on newer ones), so every id the
/// settings service reports is described until both are found by name, and nothing is ever written to a setting that wasn't identified by name (another
/// setting, `settings-reset`, wipes them all). Every write is read back; the band's own values are
/// snapshotted and written back at the end; a restore step that loses its answer is tried once more.
/// No ConfigReq afterwards (kinesis sends one): updated firmware refuses the config service (0x0300c003).
/// It owns no transport: `BandSession` sends its requests on the open connection.
final class ModelCapture {
    enum Setting: Sendable {
        case collection, model
        var name: String { self == .collection ? "data-collection" : "data-collection-model" }
        /// The value's field in a write (7 boolean, 10 enum) and in a read (8, 11).
        var writeField: UInt32 { self == .collection ? 7 : 10 }
        var readField: UInt32 { self == .collection ? 8 : 11 }
    }

    enum Operation: Equatable {
        case streams(Bool), claim, info(Int), snapshot(Setting), write(Setting, UInt64), read(Setting, UInt64)
    }

    struct Request {
        let id: UInt64
        let operation: Operation
        let deadline: Double

        var channel: UInt16 {
            switch operation {
            case .streams: 0x8005
            default: 0x8001
            }
        }
    }

    static let handwritingModel: UInt64 = 5
    /// Where the two settings sat on firmwares seen so far: described first, then every other id.
    static let likelyIDs = [27, 28, 29]

    private(set) var status = ModelCaptureStatus.idle
    private(set) var streamWanted = false
    private(set) var streamTouched = false
    private(set) var pending: Request?
    private var operations: [Operation] = []
    private var nextID: UInt64 = 0x1000_0000
    private var mutated = false
    private var restoreErrors: [String] = []
    private var problem: String?
    private var samples = 0
    private var lastSample = 0.0
    private var deadline = Double.infinity
    private var events: [SessionEvent] = []
    private var notes: [String] = []
    private var settingsCount = 0
    private var ids: [Setting: Int] = [:]
    /// Every setting name the lookup saw, for the log when the two aren't found.
    private var seenNames: [Int: String] = [:]
    private var lookupDone = false
    private var recovering = false
    /// The band's own values before this capture.
    private var original: [Setting: UInt64] = [:]
    private var retriedRestore = false

    private var normalCollection: UInt64 { original[.collection].flatMap { $0 == 0 ? $0 : nil } ?? 0 }
    private var normalModel: UInt64 { original[.model].flatMap { $0 == Self.handwritingModel ? nil : $0 } ?? 2 }

    func start(at time: Double) throws {
        guard !status.active else { throw BandError.busy("A band model capture is already running") }
        reset(at: time)
        operations = [.streams(true), .claim]
        deadline = time + 60
        publish(.preparing, "Finding the band's handwriting settings…", at: time)
    }

    /// Puts the settings back after a capture that never finished (app killed, link lost).
    func recoverNormalMode(at time: Double) throws {
        guard !status.active else { throw BandError.busy("A band model operation is already running") }
        reset(at: time)
        recovering = true
        mutated = true
        operations = [.claim]
        deadline = time + 70
        publish(.restoring, "Restoring the band's normal mode after an interrupted capture…", at: time)
    }

    func restore(at time: Double) {
        guard status.active, status.phase != .restoring else { return }
        pending = nil
        var steps: [Operation] = []
        if mutated, let _ = ids[.collection], let _ = ids[.model] {
            steps = [.write(.model, normalModel), .write(.collection, normalCollection),
                     .read(.model, normalModel), .read(.collection, normalCollection)]
        }
        operations = steps + [.streams(false)]
        deadline = time + 35
        publish(.restoring, "Restoring the band's normal mode…", at: time)
    }

    private func reset(at time: Double) {
        problem = nil; restoreErrors = []; mutated = false; samples = 0; lastSample = time
        pending = nil; original = [:]; retriedRestore = false; ids = [:]; lookupDone = false
        settingsCount = 0; recovering = false; seenNames = [:]
    }

    /// After the name lookup, queue what comes next (capture or recovery), or stop without writing.
    private func afterLookup(at time: Double) {
        lookupDone = true
        guard let collection = ids[.collection], let model = ids[.model] else {
            note("settings lookup found collection \(ids[.collection].map(String.init) ?? "none"), model \(ids[.model].map(String.init) ?? "none"): not writing anything")
            note("settings seen: " + seenNames.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", "))
            if recovering {
                restoreErrors.append("this band's model settings weren't found by name")
                operations = [.streams(false)]
            } else {
                let related = seenNames.values.filter { name in ["collect", "model", "hw", "writ"].contains { name.contains($0) } }.sorted()
                let hint = related.isEmpty ? "" : " (related settings: \(related.joined(separator: ", ")))"
                fail("none of this band's \(settingsCount) settings is named \(Setting.collection.name) and \(Setting.model.name), so nothing was changed\(hint)",
                     at: time, retry: false)
            }
            return
        }
        note("handwriting settings found by name: data-collection = \(collection), data-collection-model = \(model)")
        if recovering {
            operations = [.write(.model, 2), .write(.collection, 0), .read(.model, 2), .read(.collection, 0), .streams(false)]
        } else {
            operations = [.snapshot(.collection), .snapshot(.model), .write(.collection, 1), .write(.model, Self.handwritingModel),
                          .read(.collection, 1), .read(.model, Self.handwritingModel)]
        }
    }

    /// Bytes are framed by the session; this returns the next request to send, if any.
    func next(at time: Double) -> Request? {
        guard status.active else { return nil }
        if time >= deadline {
            fail("the band model operation timed out", at: time, retry: false)
            if status.phase == .restoring, time >= deadline {
                operations = []
                pending = nil
                complete(at: time)
            }
        }
        if let pending, time >= pending.deadline {
            if case .info = pending.operation {
                // A lookup the band doesn't answer: that id isn't one of ours.
                self.pending = nil
            } else {
                fail("the band didn't answer a model request", at: time)
            }
        }
        guard pending == nil, status.active else { return nil }
        if !operations.isEmpty {
            let operation = operations.removeFirst()
            if case .streams(let wanted) = operation { streamTouched = true; streamWanted = wanted }
            if case .write = operation { mutated = true }
            nextID += 1
            let timeout: Double = if case .info = operation { 1.5 } else { 5 }
            let request = Request(id: nextID, operation: operation, deadline: time + timeout)
            pending = request
            return request
        }
        if !lookupDone && (status.phase == .preparing || recovering) {
            afterLookup(at: time)
            return next(at: time)
        }
        if status.phase == .restoring {
            complete(at: time)
        } else if status.phase == .preparing, samples >= 5, time - lastSample < 2 {
            deadline = time + 360
            publish(.ready, "Handwriting model ready: write with your index finger", at: time)
        } else if status.phase == .ready, time - lastSample > 4 {
            fail("the band model stopped sending samples", at: time)
        }
        return nil
    }

    func payload(for request: Request, streamControl: [UInt8]) -> [UInt8] {
        let arm: UInt32
        let body: [UInt8]
        func id(_ setting: Setting) -> UInt64 { UInt64(ids[setting] ?? 0) }
        switch request.operation {
        case .streams: arm = 4; body = streamControl
        case .claim: arm = 14; body = Proto.field(1, bytes: Proto.field(1, 2))
        case .info(let settingID): arm = 14; body = Proto.field(2, bytes: Proto.field(1, 2) + Proto.field(2, UInt64(settingID)))
        case .write(let setting, let value):
            arm = 14
            body = Proto.field(3, bytes: Proto.field(1, id(setting)) + Proto.field(2, 1) + Proto.field(setting.writeField, bytes: Proto.field(1, value)))
        case .read(let setting, _), .snapshot(let setting):
            arm = 14
            body = Proto.field(3, bytes: Proto.field(1, id(setting)) + Proto.field(2, 0))
        }
        return Proto.field(1, request.id) + Proto.field(arm, bytes: body)
    }

    /// Returns true when `payload` answered the pending request.
    @discardableResult
    func receive(channel: UInt16, payload: [UInt8], at time: Double) -> Bool {
        // Newer and older firmware alike set extra bits (0x1c00) on channels they answer: compare the low byte.
        // Anything else on the channel (a firmware log, another service's answer) isn't ours.
        guard let pending, channel & 0x00ff == pending.channel & 0x00ff,
              let fields = try? ProtoFields(parsing: payload), fields.optionalInteger(1) == pending.id else { return false }
        do {
            let ok = try fields.integer(2) == 1
            if case .info = pending.operation, !ok {
                self.pending = nil // not an id of ours
                return true
            }
            guard time < pending.deadline, ok else { throw perr("the band rejected or timed out a model request") }
            switch pending.operation {
            case .streams(let enabled):
                let flags = try ProtoFields(parsing: try fields.bytes(5))
                guard try [UInt32(4), 22, 23].allSatisfy({ try flags.integer($0) == (enabled ? 1 : 0) }) else {
                    throw perr("the band didn't confirm the model streams")
                }
            case .claim:
                let count = try ProtoFields(parsing: try ProtoFields(parsing: try fields.bytes(14)).bytes(1))
                settingsCount = Int(try count.integer(1))
                note("band settings service: \(settingsCount) settings")
                guard settingsCount > 0 else { throw perr("model controls are unavailable on this band") }
                // Ids run 1…count; 0 too in case a firmware counts from zero. Unknown ids are refused quickly.
                let all = Array(0...min(settingsCount, 256))
                operations.insert(contentsOf: (Self.likelyIDs.filter(all.contains) + all.filter { !Self.likelyIDs.contains($0) }).map { .info($0) }, at: 0)
            case .info(let settingID):
                // A description without the expected shape is skipped (logged by shape only): it isn't one of ours.
                guard let info = try? ProtoFields(parsing: try ProtoFields(parsing: try fields.bytes(14)).bytes(2)),
                      let name = info.text(3) else {
                    note("setting \(settingID): unexpected description \(fields.readable(skipping: [1, 2]))")
                    break
                }
                note("setting \(settingID) is \"\(name)\"")
                seenNames[settingID] = name
                if info.optionalInteger(4) == UInt64(settingID) {
                    if name == Setting.collection.name { ids[.collection] = settingID }
                    if name == Setting.model.name { ids[.model] = settingID }
                }
                if ids[.collection] != nil, ids[.model] != nil {
                    operations.removeAll { if case .info = $0 { true } else { false } }
                }
            case .write(let setting, _), .read(let setting, _), .snapshot(let setting):
                let response = try ProtoFields(parsing: try ProtoFields(parsing: try fields.bytes(14)).bytes(3))
                let writing: Bool = if case .write = pending.operation { true } else { false }
                guard let settingID = ids[setting], try response.integer(1) == UInt64(settingID),
                      try response.integer(2) == (writing ? 1 : 0), try response.integer(3) == 0 else {
                    throw perr("the band refused a model setting")
                }
                if case .read(_, let expected) = pending.operation {
                    let value = try ProtoFields(parsing: try response.bytes(setting.readField)).integer(1)
                    guard value == expected else { throw perr("model setting readback didn't match (\(value) ≠ \(expected))") }
                }
                if case .snapshot = pending.operation {
                    let value = try ProtoFields(parsing: try response.bytes(setting.readField)).integer(1)
                    original[setting] = value
                    note("snapshot: \(setting.name) = \(value)")
                }
            }
            self.pending = nil
        } catch {
            fail(error.localizedDescription, at: time)
        }
        return true
    }

    /// An error word (0x03……) on the channel a request waits on: the band refusing that service.
    /// Fails (and restores) at once instead of waiting out the timeout. True when it was ours.
    func rejected(channel: UInt16, word: UInt32, at time: Double) -> Bool {
        guard let pending, channel & 0x00ff == pending.channel & 0x00ff else { return false }
        fail("the band refused a model request (0x\(String(word, radix: 16)) on 0x\(String(channel, radix: 16)))", at: time)
        return true
    }

    func receive(_ sample: InferenceSample, at time: Double) {
        guard status.active, sample.pipeline == 3, status.phase != .restoring else { return }
        guard sample.isTextDistribution else {
            fail("the band model output has an unsupported shape (pipeline \(sample.pipeline), \(sample.values.count) values)", at: time)
            return
        }
        samples += 1
        lastSample = time
        if status.phase == .ready { deadline = time + 360 }
    }

    func drainEvents() -> [SessionEvent] { defer { events = [] }; return events }
    func drainNotes() -> [String] { defer { notes = [] }; return notes }

    private func note(_ text: String) { notes.append(text) }

    private func fail(_ message: String, at time: Double, retry: Bool = true) {
        let failed = pending?.operation
        pending = nil
        note("problem: \(message)")
        if retry, status.phase == .restoring, !retriedRestore, let failed, failed != .claim {
            retriedRestore = true
            operations.insert(failed, at: 0)
            return
        }
        if status.phase == .restoring {
            restoreErrors.append(message)
        } else {
            problem = message
            restore(at: time)
        }
    }

    private func complete(at time: Double) {
        let verified = restoreErrors.isEmpty
        if !verified { problem = ([problem].compactMap { $0 } + restoreErrors).joined(separator: "; ") }
        let message = verified ? (mutated ? "Band back in its normal mode (verified)" : "Stopped; nothing was changed") : "Couldn't verify the band's normal mode"
        publish(.finished, message, verified: verified, at: time)
    }

    private func publish(_ phase: ModelCaptureStatus.Phase, _ message: String, verified: Bool = false, at time: Double) {
        status = ModelCaptureStatus(phase: phase, message: message, problem: problem, restorationVerified: verified)
        events.append(.modelCaptureState(status))
    }
}
