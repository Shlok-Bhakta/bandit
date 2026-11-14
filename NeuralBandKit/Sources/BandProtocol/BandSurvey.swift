import Foundation

/// One entry of the band's settings service, as described and read (never written).
public struct BandSetting: Sendable, Equatable, Identifiable {
    public let id: Int
    public var name: String?
    /// The rest of the description message (everything but name and id), readable.
    public var details: String = ""
    /// The value as read: nil until read or when the read failed.
    public var value: String?
    /// "bool", "enum" or "field N" (the read message's value field).
    public var valueKind: String?
    public var problem: String?

    /// Never written by this app outside the handwriting capture; `settings-reset` never at all.
    public var dangerous: Bool { name == "settings-reset" }
}

/// The band's firmware update service status (`OtaResp.deviceInfoResponse`), read only.
public struct OtaStatus: Sendable, Equatable {
    /// `OtaState`: 0 unavailable, 1 idle, 2 in progress, 3 ready (staged).
    public var state: UInt64
    /// `DeviceState`: 0 stable, 1 trial, 2 recovery firmware.
    public var device: UInt64
    /// `UnavailableReason` when unavailable.
    public var reason: UInt64
    /// The version of the firmware encryption key (KEK) the band holds. An id, not key material.
    public var kek: UInt64
    public var activeFirmware: UInt64?
    public var stagedFirmware: UInt64?
    public var mlModel: UInt64?
    public var raw: String

    public var stateName: String { ["unavailable", "idle", "update in progress", "update ready (staged)"][safe: Int(state)] ?? "state \(state)" }
    public var deviceName: String { ["stable firmware", "TRIAL firmware", "RECOVERY firmware"][safe: Int(device)] ?? "device state \(device)" }
    public var reasonName: String? {
        reason == 0 ? nil : ["none", "no BLE", "disabled on the band", "power (charge the band)", "trial firmware running"][safe: Int(reason)] ?? "reason \(reason)"
    }

    /// From the `DeviceInfoResponse` message itself.
    static func read(_ info: ProtoFields) -> OtaStatus {
        var status = OtaStatus(state: info.optionalInteger(4) ?? 0, device: info.optionalInteger(3) ?? 0, reason: info.optionalInteger(7) ?? 0,
                               kek: info.optionalInteger(6) ?? 0, raw: info.readable())
        for (field, bytes) in info.byteFields() where field == 5 {
            guard let item = try? ProtoFields(parsing: bytes), let kind = item.optionalInteger(1), let version = item.optionalInteger(2) else { continue }
            switch kind {
            case 0: status.activeFirmware = version
            case 1: status.stagedFirmware = version
            case 2: status.mlModel = version
            default: break
            }
        }
        return status
    }

    /// From a whole `RpcResponse` carrying `OtaResp.deviceInfoResponse` (field 8 → 2).
    static func parse(response: ProtoFields) -> OtaStatus? {
        guard let outer = try? ProtoFields(parsing: response.bytes(8)), let info = try? ProtoFields(parsing: outer.bytes(2)) else { return nil }
        return read(info)
    }
}

/// Everything the read-only survey learned.
public struct BandSurveyReport: Sendable, Equatable {
    public enum Phase: Sendable { case idle, running, finished }
    public var phase: Phase = .idle
    public var message = ""
    public var settingsCount: Int?
    public var settings: [BandSetting] = []
    /// The band's whole config (`Config`, from an empty `ConfigReq` on 0x8007), readable, by field.
    public var config: [(field: UInt32, value: String)] = []
    public var ota: OtaStatus?
    public var problems: [String] = []

    public init() {}

    public static func == (a: BandSurveyReport, b: BandSurveyReport) -> Bool {
        a.phase == b.phase && a.message == b.message && a.settingsCount == b.settingsCount && a.settings == b.settings
            && a.config.map(\.field) == b.config.map(\.field) && a.config.map(\.value) == b.config.map(\.value)
            && a.ota == b.ota && a.problems == b.problems
    }
}

/// A read-only tour of what the band exposes: the settings service (count, then describe and read
/// every id), the whole config and the update service's status. It only ever sends reads: settings
/// requests carry `2: 0` (read), config is an empty `ConfigReq`, update status an empty
/// `deviceInfoRequest`. Nothing here can change the band. `BandSession` frames and routes it.
final class BandSurvey {
    enum Operation: Equatable { case count, describe(Int), read(Int), config, ota }

    struct Request {
        let id: UInt64
        let operation: Operation
        let deadline: Double

        var channel: UInt16 {
            switch operation {
            case .config: 0x8007
            case .ota: 0x8006
            default: 0x8001
            }
        }
    }

    private(set) var report = BandSurveyReport()
    private(set) var pending: Request?
    private var operations: [Operation] = []
    private var nextID: UInt64 = 0x2000_0000
    private var events: [SessionEvent] = []
    private var notes: [String] = []
    private var statusOnly = false

    var running: Bool { report.phase == .running }

    func start(at time: Double, updateStatusOnly: Bool = false) {
        guard !running else { return }
        let previous = report
        report = BandSurveyReport()
        if updateStatusOnly {
            // Keep what an earlier full survey found.
            report.settingsCount = previous.settingsCount
            report.settings = previous.settings
            report.config = previous.config
        }
        report.phase = .running
        statusOnly = updateStatusOnly
        report.message = updateStatusOnly ? "Asking the band's update status…" : "Counting the band's settings…"
        operations = updateStatusOnly ? [.ota] : [.count]
        pending = nil
        publish()
    }

    func next(at time: Double) -> Request? {
        guard running else { return nil }
        if let pending, time >= pending.deadline {
            problem(for: pending.operation, "no answer")
            self.pending = nil
        }
        guard pending == nil else { return nil }
        guard !operations.isEmpty else {
            report.phase = .finished
            report.message = statusOnly && report.settingsCount == nil
                ? (report.ota == nil ? "The band didn't report its update status" : "Update status read; settings not read yet")
                : "Survey finished: \(report.settings.count) settings, \(report.config.count) config fields\(report.ota == nil ? "" : ", update status")"
            note(report.message)
            publish()
            return nil
        }
        let operation = operations.removeFirst()
        nextID += 1
        let timeout: Double = if case .describe = operation { 1.5 } else { 3 }
        let request = Request(id: nextID, operation: operation, deadline: time + timeout)
        pending = request
        return request
    }

    func payload(for request: Request) -> [UInt8] {
        let body: [UInt8]
        switch request.operation {
        case .count: body = Proto.field(14, bytes: Proto.field(1, bytes: Proto.field(1, 2)))
        case .describe(let id): body = Proto.field(14, bytes: Proto.field(2, bytes: Proto.field(1, 2) + Proto.field(2, UInt64(id))))
        // `2: 0` = read. The survey never sends `2: 1` (write).
        case .read(let id): body = Proto.field(14, bytes: Proto.field(3, bytes: Proto.field(1, UInt64(id)) + Proto.field(2, 0)))
        case .config: body = Proto.field(5, bytes: [])
        case .ota: body = Proto.field(7, bytes: Proto.field(1, bytes: []))
        }
        return Proto.field(1, request.id) + body
    }

    /// True when `payload` answered the pending request.
    @discardableResult
    func receive(channel: UInt16, payload: [UInt8], at time: Double) -> Bool {
        guard let pending, channel & 0x00ff == pending.channel & 0x00ff,
              let fields = try? ProtoFields(parsing: payload), fields.optionalInteger(1) == pending.id else { return false }
        self.pending = nil
        guard fields.optionalInteger(2) == 1 else {
            problem(for: pending.operation, "rejected (status \(fields.optionalInteger(2) ?? 0))")
            if pending.operation == .count { operations = [.config, .ota] }
            return true
        }
        switch pending.operation {
        case .count:
            guard let response = try? ProtoFields(parsing: fields.bytes(14)), let count = try? ProtoFields(parsing: response.bytes(1)),
                  let total = count.optionalInteger(1), total > 0 else {
                problem(for: .count, "unexpected answer: \(fields.readable(skipping: [1, 2]))")
                operations = [.config, .ota]
                break
            }
            let shown = min(Int(total), 256)
            report.settingsCount = Int(total)
            report.settings = (1...shown).map { BandSetting(id: $0) }
            operations = (1...shown).flatMap { [Operation.describe($0), .read($0)] } + [.config, .ota]
            report.message = "Reading \(shown) settings…"
            note("settings service has \(total) settings")
        case .describe(let id):
            guard let index = report.settings.firstIndex(where: { $0.id == id }) else { break }
            guard let response = try? ProtoFields(parsing: fields.bytes(14)), let info = try? ProtoFields(parsing: response.bytes(2)) else {
                report.settings[index].problem = "unexpected description: \(fields.readable(skipping: [1, 2]))"
                break
            }
            report.settings[index].name = info.text(3)
            report.settings[index].details = info.readable(skipping: [3, 4])
            note("setting \(id): \(info.text(3) ?? "?") \(report.settings[index].details)")
        case .read(let id):
            guard let index = report.settings.firstIndex(where: { $0.id == id }) else { break }
            guard let response = try? ProtoFields(parsing: fields.bytes(14)), let read = try? ProtoFields(parsing: response.bytes(3)) else {
                report.settings[index].problem = "unexpected read: \(fields.readable(skipping: [1, 2]))"
                break
            }
            if let status = read.optionalInteger(3), status != 0 { report.settings[index].problem = "read status \(status)" }
            let valueFields = read.fieldNumbers.filter { ![1, 2, 3].contains($0) }
            if let field = valueFields.first {
                report.settings[index].valueKind = switch field { case 8: "bool"; case 11: "enum"; default: "field \(field)" }
                if let bytes = try? read.bytes(field), let inner = try? ProtoFields(parsing: bytes) {
                    report.settings[index].value = inner.optionalInteger(1).map(String.init) ?? inner.text(1).map { "\"\($0)\"" } ?? inner.readable()
                } else {
                    report.settings[index].value = read.readable(skipping: [1, 2, 3])
                }
            }
            if id.isMultiple(of: 8) {
                report.message = "Reading settings… \(id)/\(report.settings.count)"
                publish()
            }
        case .config:
            guard let config = try? ProtoFields(parsing: fields.bytes(6)) else {
                problem(for: .config, "unexpected answer: \(fields.readable(skipping: [1, 2]))")
                break
            }
            report.config = config.fieldNumbers.map { ($0, ProtoFields.single(config, $0)) }
            note("config: \(config.readable())")
        case .ota:
            if let status = OtaStatus.parse(response: fields) {
                report.ota = status
                note("update service: \(status.stateName), \(status.deviceName), firmware \(status.activeFirmware.map(String.init) ?? "?"), ML \(status.mlModel.map(String.init) ?? "?")")
            } else {
                problem(for: .ota, "unexpected answer: \(fields.readable(skipping: [1, 2]))")
            }
        }
        return true
    }

    func drainEvents() -> [SessionEvent] { defer { events = [] }; return events }
    func drainNotes() -> [String] { defer { notes = [] }; return notes }

    private func note(_ text: String) { notes.append(text) }
    private func publish() { events.append(.surveyUpdated(report)) }

    private func problem(for operation: Operation, _ text: String) {
        switch operation {
        case .describe(let id), .read(let id):
            if let index = report.settings.firstIndex(where: { $0.id == id }), report.settings[index].problem == nil {
                report.settings[index].problem = text
            }
        case .count: report.problems.append("settings count: \(text)")
        case .config: report.problems.append("config: \(text)")
        case .ota: report.problems.append("update status: \(text)")
        }
        note("\(operation): \(text)")
    }
}

extension ProtoFields {
    /// One field's value(s), readable, without the leading "N=".
    static func single(_ fields: ProtoFields, _ field: UInt32) -> String {
        let mine = fields.readable(skipping: Set(fields.fieldNumbers).subtracting([field]))
        return mine.replacingOccurrences(of: "\(field)=", with: "", options: .anchored)
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
