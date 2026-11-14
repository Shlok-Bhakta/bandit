import Foundation

/// Firmware update over the band's RPC service, as Meta AI does it (`emg_ota.proto`,
/// `bulk_transfer.proto`). A port of band-core `ota.rs` (MIT, by David Ljung Madison Stellar):
/// update status, the key (KEK) if the band lacks it, then for the firmware and the ML bundle
/// Start, a bulk transfer and Verify, and at the end either Abort (a trial: nothing is installed)
/// or Commit (the band reboots into the new firmware).
///
/// Sans-IO like the session: `OtaJob` hands out `RpcRequest` bodies and reads the matching
/// `RpcResponse`s; `BandSession` frames, encrypts and routes them. Progress goes to `takeLog()`.

/// Which part of an update to run. Each is its own command so a person decides on the next.
public enum OtaMode: String, Sendable, CaseIterable {
    /// Install the package's key on the band if it lacks it. Persistent.
    case key
    /// Send each item and have the band verify it, then stop: the update stays staged (not installed).
    case send
    /// Key, Send, then Abort: nothing stays staged. (The key, if installed, stays.)
    case trial
    /// Abort whatever update the band holds (in progress or staged).
    case cancel
    /// Commit a staged update: the band reboots into it. Probably one-way.
    case install
    /// All of it in one connection, as Meta AI does: abort any earlier update, the key if needed,
    /// send and verify each item, then Commit. The band refuses a Commit once the connection that
    /// verified the items is gone.
    case update
}

public struct OtaPlan: Sendable {
    /// The server's `target_version`, sent as both items' version.
    public var version: UInt64
    public var firmware: [UInt8]
    public var firmwareMD5: [UInt8]
    /// The ML bundle with its MD5, when the package has one.
    public var model: (data: [UInt8], md5: [UInt8])?
    /// The package's key, wrapped for this band by Meta: its version (id) and the wrapped bytes.
    public var kek: (id: UInt64, key: [UInt8])?
    public var mode: OtaMode
    /// Pick up an interrupted update instead of aborting it.
    public var resume: Bool

    public init(version: UInt64, firmware: [UInt8], firmwareMD5: [UInt8], model: (data: [UInt8], md5: [UInt8])?,
                kek: (id: UInt64, key: [UInt8])?, mode: OtaMode, resume: Bool = false) {
        self.version = version
        self.firmware = firmware
        self.firmwareMD5 = firmwareMD5
        self.model = model
        self.kek = kek
        self.mode = mode
        self.resume = resume
    }

    public static let cancel = OtaPlan(version: 0, firmware: [], firmwareMD5: Array(repeating: 0, count: 16), model: nil, kek: nil, mode: .cancel)
}

/// One file of an update, for a progress meter.
public struct OtaItemProgress: Sendable, Equatable {
    public let name: String
    public let size: Int
    /// Bytes the band has acknowledged.
    public let sent: Int
    /// "waiting", "sending", "checking" or "done" (verified by the band).
    public let stage: String
}

extension OtaStatus {
    public var summary: String {
        func shown(_ value: UInt64?) -> String { value.map(String.init) ?? "-" }
        var text = "\(stateName), \(deviceName), active \(shown(activeFirmware)), staged \(shown(stagedFirmware)), ML \(shown(mlModel)), key \(kek)"
        if state == 0, let reasonName { text += ", unavailable: \(reasonName)" }
        return text
    }
}

final class OtaJob {
    static let chunk = 950
    static let replySeconds = 5.0
    static let chunkRetries = 4
    static let rateWindow = 30.0
    /// At most this many chunks in flight (what the factory firmware offered; larger windows dropped links).
    static let maxWindow = 8
    /// Meta AI only sends an ML bundle bigger than this.
    static let mlMinimum = 10 * 1024

    static let activeFirmware: UInt64 = 0
    static let latestFirmware: UInt64 = 1
    static let mlModel: UInt64 = 2

    enum Ask: Equatable { case first, afterReset, afterKek, last }
    enum Step: Equatable { case status(Ask), reset, kek, start, transferInfo, verify, abort, commit, rescue }

    struct Item {
        let kind: UInt64
        let name: String
        let data: [UInt8]
        let md5: [UInt8]
    }

    struct Sent {
        let seq: UInt64
        let at: Double
        let tries: Int
    }

    struct Transfer {
        let id: UInt64
        var next = 0
        var window = 0
        var pending: [Int: Sent] = [:]
        var started: Double
        var samples: [(at: Double, bytes: Int)] = []
        var shown = 0
    }

    private var plan: OtaPlan
    private(set) var items: [Item] = []
    private var item = 0
    private var waiting: (id: UInt64, deadline: Double, step: Step)?
    private var transfer: Transfer?
    private var transferIDs: UInt64 = 0
    private var log: [String] = []
    private(set) var done = false
    /// Commit was sent: from here nothing may be aborted.
    private(set) var committed = false
    /// Commit was answered OK.
    private(set) var commitAccepted = false
    /// The band's latest status answer to this job.
    private(set) var lastStatus: OtaStatus?

    init(plan: OtaPlan) { self.plan = plan }

    var mode: OtaMode { plan.mode }
    var version: UInt64 { plan.version }

    /// Whether stopping now is safe: Commit not yet sent. Before it the band keeps running its firmware.
    var cancellable: Bool {
        if committed { return false }
        if case .commit = waiting?.step { return false }
        return true
    }

    var progress: [OtaItemProgress] {
        items.enumerated().map { index, item in
            let size = item.data.count
            if index < self.item { return OtaItemProgress(name: item.name, size: size, sent: size, stage: "done") }
            if index > self.item { return OtaItemProgress(name: item.name, size: size, sent: 0, stage: "waiting") }
            if let transfer {
                return OtaItemProgress(name: item.name, size: size, sent: min(max(transfer.next - transfer.pending.count * Self.chunk, 0), size), stage: "sending")
            }
            if case .verify = waiting?.step { return OtaItemProgress(name: item.name, size: size, sent: size, stage: "checking") }
            return OtaItemProgress(name: item.name, size: size, sent: 0, stage: "waiting")
        }
    }

    func takeLog() -> [String] { defer { log = [] }; return log }

    private func say(_ line: String) { log.append(line) }

    /// The first request (the update status, or Abort to cancel). `ids` is the session's request counter.
    func begin(ids: inout UInt64, now: Double) -> [[UInt8]] {
        let kind: String
        switch plan.mode {
        case .key: kind = "key"
        case .send: kind = "send and verify (stays staged; not installed)"
        case .trial: kind = "trial (ends with Abort; nothing is installed)"
        case .cancel:
            say("cancelling the band's update")
            return [ask(.abort, ids: &ids, now: now)]
        case .install: kind = "INSTALL of the staged update (Commit)"
        case .update: kind = "UPDATE in one go (send, verify, then Commit)"
        }
        say("\(kind) of \(plan.version)")
        return [ask(.status(.first), ids: &ids, now: now)]
    }

    /// Whether `seq` is one of ours.
    func owns(_ seq: UInt64) -> Bool {
        waiting?.id == seq || (transfer?.pending.values.contains { $0.seq == seq } ?? false)
    }

    private func ota(_ ids: inout UInt64, _ request: [UInt8]) -> (UInt64, [UInt8]) {
        ids += 1
        return (ids, Proto.field(1, ids) + Proto.field(7, bytes: request))
    }

    private static func bulk(_ ids: inout UInt64, _ request: [UInt8]) -> (UInt64, [UInt8]) {
        ids += 1
        return (ids, Proto.field(1, ids) + Proto.field(9, bytes: request))
    }

    private func itemInfo(_ kind: UInt64) -> [UInt8] { Proto.field(1, kind) + Proto.field(2, plan.version) }

    /// Build and remember the request for `step`.
    private func ask(_ step: Step, ids: inout UInt64, now: Double) -> [UInt8] {
        let request: [UInt8]
        switch step {
        case .status: request = Proto.field(1, bytes: [])
        case .reset, .abort, .rescue: request = Proto.field(5, bytes: [])
        case .kek:
            let kek = plan.kek!
            request = Proto.field(6, bytes: Proto.field(1, kek.id) + Proto.field(2, 0) + Proto.field(3, bytes: kek.key))
        case .start:
            let item = items[self.item]
            request = Proto.field(2, bytes: Proto.field(1, bytes: itemInfo(item.kind)) + Proto.field(2, UInt64(item.data.count))
                                  + Proto.field(3, 0) + Proto.field(4, 0))
        case .verify: request = Proto.field(3, bytes: Proto.field(1, bytes: itemInfo(items[item].kind)))
        case .commit: request = Proto.field(4, bytes: Proto.field(1, 0))
        case .transferInfo: preconditionFailure("sent by startTransfer")
        }
        let (seq, body) = ota(&ids, request)
        waiting = (seq, now + Self.replySeconds * 3, step)
        return body
    }

    /// Something went wrong: say so, and unless committed, abort whatever the band holds (trial/update only).
    private func fail(_ why: String, ids: inout UInt64, now: Double) -> [[UInt8]] {
        say("FAILED: \(why)")
        transfer = nil
        if committed || ![.trial, .update].contains(plan.mode) {
            done = true
            return []
        }
        say("aborting, so nothing stays staged")
        return [ask(.rescue, ids: &ids, now: now)]
    }

    /// The `Result.resultCode` inside a reply message (0 = OK; a Result left at OK can arrive empty).
    static func resultCode(_ message: [UInt8]) -> UInt64? {
        guard let message = try? ProtoFields(parsing: message), let result = try? ProtoFields(parsing: message.bytes(1)) else { return nil }
        return try? result.integer(1)
    }

    static func resultName(_ code: UInt64) -> String {
        let name = switch code {
        case 0: "OK"
        case 100: "INVALID_ITEM"
        case 200: "REJECTED_NO_SPACE"
        case 201: "REJECTED_POWER_STATE"
        case 202: "REJECTED_OLD_VERSION"
        case 203: "REJECTED_UPDATE_IN_PROGRESS"
        case 204: "REJECTED_NO_UPDATE_IN_PROGRESS"
        case 205: "REJECTED_INCORRECT_STATE"
        case 206: "REJECTED_RUNNING_TRIAL_FIRMWARE"
        case 207: "REJECTED_MISMATCHED_KEK_VERSION"
        case 208: "REJECTED_INVALID_KEK"
        case 209: "REJECTED_KEK_INSTALL_FAILED"
        case 300: "INCORRECT_FILE_CHECKSUM"
        default: "unknown"
        }
        return "\(name) (\(code))"
    }

    private static func shown(_ code: UInt64?) -> String { code.map(resultName) ?? "no result" }

    /// The response to one of our requests (`fields` = the whole `RpcResponse`).
    func receive(_ fields: ProtoFields, ids: inout UInt64, now: Double) -> [[UInt8]] {
        guard let seq = fields.optionalInteger(1) else { return [] }
        if fields.contains(10) { return receiveBulk(fields, seq: seq, ids: &ids, now: now) }
        guard let waiting, waiting.id == seq else { return [] }
        self.waiting = nil
        let step = waiting.step
        guard let response = try? ProtoFields(parsing: fields.bytes(8)) else {
            return fail("no update answer to \(step) (RPC code \(fields.optionalInteger(2) ?? 0))", ids: &ids, now: now)
        }
        switch step {
        case .status(let ask):
            return status(response, ask: ask, ids: &ids, now: now)
        case .verify:
            let code = (try? response.bytes(3)).flatMap(Self.resultCode) ?? (try? response.bytes(1)).flatMap(Self.resultCode)
            guard code == 0 else {
                say("verify answer: \(response.readable(depth: 2))")
                return fail("\(items[item].name) didn't verify: \(Self.shown(code))", ids: &ids, now: now)
            }
            say("\(items[item].name) verified by the band")
            item += 1
            return nextItem(ids: &ids, now: now)
        case .commit:
            committed = true
            done = true
            let code = (try? response.bytes(4)).flatMap(Self.resultCode) ?? (try? response.bytes(1)).flatMap(Self.resultCode)
            say("commit answer: \(response.readable(depth: 2))")
            if code == 0 {
                commitAccepted = true
                say("COMMITTED: the band now reboots into the new firmware; the app checks it on reconnecting")
            } else {
                say("commit answered \(Self.shown(code))")
            }
            return []
        default:
            return general(step, code: (try? response.bytes(1)).flatMap(Self.resultCode), ids: &ids, now: now)
        }
    }

    /// A `GeneralResponse` to Reset, Kek, Start, Abort or Rescue.
    private func general(_ step: Step, code: UInt64?, ids: inout UInt64, now: Double) -> [[UInt8]] {
        let shown = Self.shown(code)
        switch step {
        case .reset:
            say("abort of the earlier update: \(shown)")
            return [ask(.status(.afterReset), ids: &ids, now: now)]
        case .kek where code == 0:
            say("key installed; checking")
            return [ask(.status(.afterKek), ids: &ids, now: now)]
        case .kek:
            return fail("the band refused the key: \(shown)", ids: &ids, now: now)
        case .start where code == 0:
            say("\(items[item].name): start accepted")
            return startTransfer(ids: &ids, now: now)
        case .start:
            return fail("\(items[item].name): start refused: \(shown)", ids: &ids, now: now)
        case .abort:
            // REJECTED_INCORRECT_STATE when nothing was staged is harmless.
            say("aborted: \(shown); checking nothing is staged")
            return [ask(.status(.last), ids: &ids, now: now)]
        case .rescue:
            say("abort after the failure: \(shown)")
            done = true
            return []
        default:
            return []
        }
    }

    private func status(_ response: ProtoFields, ask: Ask, ids: inout UInt64, now: Double) -> [[UInt8]] {
        guard let info = try? ProtoFields(parsing: response.bytes(2)) else {
            return fail("the status answer had no device info", ids: &ids, now: now)
        }
        let status = OtaStatus.read(info)
        lastStatus = status
        let (state, kek) = (status.state, status.kek)
        say("status: \(status.summary)")
        switch ask {
        case .last:
            done = true
            let clean = state == 1 && status.stagedFirmware == status.activeFirmware
            switch (plan.mode, clean) {
            case (.trial, true): say("TRIAL OK: transferred and verified, then aborted; nothing is staged")
            case (_, true): say("CANCELLED: nothing is staged")
            default: say("the band doesn't look clean; check the status above")
            }
            return []
        case .first where plan.mode == .key:
            return afterStatus(kek: kek, ml: 0, ids: &ids, now: now)
        case .first where plan.mode == .install:
            guard state == 3, status.stagedFirmware == plan.version else {
                done = true
                say("nothing to install: \(plan.version) isn't staged (send it first)")
                return []
            }
            // The band refuses a Commit in a later connection than the Verifies: verify each staged item again, then commit.
            chooseItems(ml: .max)
            return nextItem(ids: &ids, now: now)
        case .first, .afterReset:
            if status.activeFirmware == plan.version {
                done = true
                say("the band already runs this version; nothing to do")
                return []
            }
            if plan.resume, state == 2 { return resume(kek: kek, ids: &ids, now: now) }
            let staged = status.stagedFirmware == plan.version
            let busy = state == 2 || state == 3
            if state == 0 { return fail("the band says updates are unavailable now", ids: &ids, now: now) }
            if state == 3, staged, plan.mode != .update, kek == (plan.kek?.id ?? kek) {
                // As Meta AI: this firmware is already received and verified; send the rest.
                say("this firmware is already staged; skipping it")
                chooseItems(ml: status.mlModel ?? 0)
                item = 1
                return nextItem(ids: &ids, now: now)
            }
            if busy, ![.trial, .update].contains(plan.mode) {
                done = true
                say("another update is in progress or staged; cancel it first")
                return []
            }
            if busy, ask == .first {
                say("an earlier update is in progress or staged; aborting it first")
                return [self.ask(.reset, ids: &ids, now: now)]
            }
            if state == 1 { return afterStatus(kek: kek, ml: status.mlModel ?? 0, ids: &ids, now: now) }
            return fail("the band is still busy with an earlier update", ids: &ids, now: now)
        case .afterKek:
            let want = plan.kek?.id ?? 0
            guard kek == want else { return fail("the band still reports key \(kek), not \(want)", ids: &ids, now: now) }
            say("the band now has key \(kek)")
            if plan.mode == .key {
                done = true
                return []
            }
            return afterStatus(kek: kek, ml: status.mlModel ?? 0, ids: &ids, now: now)
        }
    }

    /// `resume`: continue the last item of an update the band still holds.
    private func resume(kek: UInt64, ids: inout UInt64, now: Double) -> [[UInt8]] {
        let want = plan.kek?.id ?? kek
        guard kek == want else {
            done = true
            say("nothing to resume: the band has key \(kek), not \(want)")
            return []
        }
        chooseItems(ml: .max)
        item = items.count - 1
        say("resuming: asking where the \(items[item].name) transfer stopped (no Start)")
        return startTransfer(ids: &ids, now: now)
    }

    /// The items to send, firmware first; the ML bundle only when newer than the band's `ml`.
    private func chooseItems(ml: UInt64) {
        guard items.isEmpty else { return }
        items.append(Item(kind: Self.activeFirmware, name: "firmware", data: plan.firmware, md5: plan.firmwareMD5))
        plan.firmware = []
        if let model = plan.model {
            if model.data.count > Self.mlMinimum, ml == .max || plan.version > ml {
                items.append(Item(kind: Self.mlModel, name: "ML bundle", data: model.data, md5: model.md5))
            } else {
                say("ML bundle skipped (the band's model \(ml) is current)")
            }
            plan.model = nil
        }
    }

    /// The band is idle: install the key if needed, choose the items, start the first.
    private func afterStatus(kek: UInt64, ml: UInt64, ids: inout UInt64, now: Double) -> [[UInt8]] {
        if let want = plan.kek?.id {
            if want != kek, plan.mode == .send {
                return fail("the band has key \(kek); install key \(want) first", ids: &ids, now: now)
            }
            if want != kek {
                say("installing key \(want) (the band has \(kek))")
                return [ask(.kek, ids: &ids, now: now)]
            }
            if plan.mode == .key {
                done = true
                say("the band already has key \(want)")
                return []
            }
        } else {
            say("no key given; the band has key \(kek), so the package must use it")
        }
        // An update sends the whole package: after an abort the band can still report the aborted
        // ML bundle's version, so its ML version can't be trusted to skip the bundle.
        chooseItems(ml: plan.mode == .update ? .max : ml)
        return nextItem(ids: &ids, now: now)
    }

    private func nextItem(ids: inout UInt64, now: Double) -> [[UInt8]] {
        if plan.mode == .install {
            if item < items.count {
                say("\(items[item].name): asking the band to verify it again")
                return [ask(.verify, ids: &ids, now: now)]
            }
            say("committing the staged update")
            return [ask(.commit, ids: &ids, now: now)]
        }
        if item < items.count {
            say("\(items[item].name): starting (\(items[item].data.count) bytes)")
            return [ask(.start, ids: &ids, now: now)]
        }
        if plan.mode == .trial {
            say("all items verified; aborting (trial)")
            return [ask(.abort, ids: &ids, now: now)]
        }
        if plan.mode == .update {
            say("all items verified; committing")
            return [ask(.commit, ids: &ids, now: now)]
        }
        done = true
        say("STAGED: \(plan.version) is received and verified, not installed; install or cancel next")
        return []
    }

    private func startTransfer(ids: inout UInt64, now: Double) -> [[UInt8]] {
        transferIDs += 1
        let item = items[self.item]
        let info = Proto.field(1, bytes: item.md5) + Proto.field(2, UInt64(item.data.count)) + Proto.field(3, 1) + Proto.field(4, transferIDs)
        let (seq, body) = Self.bulk(&ids, Proto.field(1, bytes: info))
        waiting = (seq, now + Self.replySeconds, .transferInfo)
        transfer = Transfer(id: transferIDs, started: now)
        return [body]
    }

    private func chunk(at offset: Int, ids: inout UInt64) -> (UInt64, [UInt8]) {
        let data = items[item].data
        let end = min(offset + Self.chunk, data.count)
        let body = Proto.field(1, transfer?.id ?? 0) + Proto.field(2, UInt64(offset)) + Proto.field(3, bytes: Array(data[offset..<end]))
        return Self.bulk(&ids, Proto.field(2, bytes: body))
    }

    /// Send new chunks while the window has room.
    private func fill(ids: inout UInt64, now: Double) -> [[UInt8]] {
        let size = items[item].data.count
        var out: [[UInt8]] = []
        while let transfer, transfer.pending.count < transfer.window, transfer.next < size {
            let offset = transfer.next
            let (seq, body) = chunk(at: offset, ids: &ids)
            self.transfer!.pending[offset] = Sent(seq: seq, at: now, tries: 0)
            self.transfer!.next = min(offset + Self.chunk, size)
            out.append(body)
        }
        return out
    }

    private func receiveBulk(_ fields: ProtoFields, seq: UInt64, ids: inout UInt64, now: Double) -> [[UInt8]] {
        guard let response = try? ProtoFields(parsing: fields.bytes(10)) else { return [] }
        if let waiting, waiting.id == seq, waiting.step == .transferInfo {
            self.waiting = nil
            guard let info = try? ProtoFields(parsing: response.bytes(1)) else {
                return fail("the transfer setup had no info answer", ids: &ids, now: now)
            }
            let state = info.optionalInteger(1) ?? 0
            let memory = Int(info.optionalInteger(2) ?? 0)
            let offset = Int(info.optionalInteger(3) ?? 0)
            let name = items[item].name
            say("\(name): transfer state \(state), band memory \(memory), resume at \(offset)")
            switch state {
            case 3:
                transfer = nil
                say("\(name): the band already has all of it; verifying")
                return [ask(.verify, ids: &ids, now: now)]
            case 1 where memory >= Self.chunk, 2 where memory >= Self.chunk:
                let size = items[item].data.count
                transfer!.window = min(memory / Self.chunk, Self.maxWindow)
                transfer!.next = min(offset, size)
                transfer!.samples.append((now, transfer!.next))
                transfer!.shown = transfer!.next * 100 / max(size, 1) / 5 * 5
                transfer!.started = now
                return fill(ids: &ids, now: now)
            case 1, 2:
                return fail("\(name): the band has too little memory (\(memory))", ids: &ids, now: now)
            default:
                return fail("\(name): unknown transfer state \(state)", ids: &ids, now: now)
            }
        }
        guard var transfer, let offset = transfer.pending.first(where: { $0.value.seq == seq })?.key else { return [] }
        if let nack = try? response.bytes(3) {
            let reason = (try? ProtoFields(parsing: nack))?.text(2) ?? ""
            return fail("the band refused a chunk at \(offset): \"\(reason)\"", ids: &ids, now: now)
        }
        guard let ack = try? ProtoFields(parsing: response.bytes(2)) else {
            return fail("odd answer to the chunk at \(offset)", ids: &ids, now: now)
        }
        let acked = Int(ack.optionalInteger(2) ?? UInt64(offset))
        transfer.pending[acked] = nil
        transfer.pending[offset] = nil
        let size = items[item].data.count
        let sent = min(max(transfer.next - transfer.pending.count * Self.chunk, 0), size)
        let percent = sent * 100 / max(size, 1)
        transfer.samples.append((now, sent))
        while transfer.samples.count > 2, let first = transfer.samples.first, now - first.at > Self.rateWindow { transfer.samples.removeFirst() }
        var rate: Double?
        if percent >= transfer.shown + 5 {
            transfer.shown = percent / 5 * 5
            let first = transfer.samples[0]
            rate = Double(max(sent - first.bytes, 0)) / max(now - first.at, 0.001) / 1024
        }
        let finished = transfer.pending.isEmpty && transfer.next >= size
        let seconds = now - transfer.started
        self.transfer = transfer
        let name = items[item].name
        if let rate { say("\(name): \(percent)% (\(String(format: "%.1f", rate)) KiB/s)") }
        if finished {
            self.transfer = nil
            say("\(name): sent in \(Int(seconds)) s; verifying")
            return [ask(.verify, ids: &ids, now: now)]
        }
        return fill(ids: &ids, now: now)
    }

    /// Timeouts: resend late chunks, give up on silent requests.
    func tick(ids: inout UInt64, now: Double) -> [[UInt8]] {
        if let waiting, now >= waiting.deadline {
            self.waiting = nil
            switch waiting.step {
            case .rescue:
                say("no answer to the abort after the failure; ask the status")
                done = true
                return []
            case .commit:
                committed = true
                done = true
                say("no answer to Commit (the band may be rebooting); reconnect, then check the status")
                return []
            default:
                return fail("no answer to \(waiting.step)", ids: &ids, now: now)
            }
        }
        guard let transfer else { return [] }
        let late = transfer.pending.filter { now - $0.value.at >= Self.replySeconds }.keys.sorted()
        var out: [[UInt8]] = []
        for offset in late {
            let tries = self.transfer?.pending[offset]?.tries ?? 0
            if tries >= Self.chunkRetries {
                return fail("no answer for the chunk at \(offset) after \(tries + 1) tries", ids: &ids, now: now)
            }
            let (seq, body) = chunk(at: offset, ids: &ids)
            self.transfer?.pending[offset] = Sent(seq: seq, at: now, tries: tries + 1)
            out.append(body)
        }
        return out
    }
}
