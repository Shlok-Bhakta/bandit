import CryptoKit
import Foundation

/// The ESP32 dongle's private control service ("Bandit"), sans-IO: status, commands,
/// packages and the update stream. See firmware/bandit/CONTROL.md (protocol v1).
public enum DongleGATT {
    public static let service = "4E500100-3C1A-4E0B-9D1E-6F2B5A7C8D90"
    public static let status = "4E500101-3C1A-4E0B-9D1E-6F2B5A7C8D90"
    public static let command = "4E500102-3C1A-4E0B-9D1E-6F2B5A7C8D90"
    public static let log = "4E500103-3C1A-4E0B-9D1E-6F2B5A7C8D90"
    public static let update = "4E500104-3C1A-4E0B-9D1E-6F2B5A7C8D90"
    /// Notifies "?" when the status changed (0.11.1 on; 0.11.0 notified on Status itself).
    public static let changed = "4E500105-3C1A-4E0B-9D1E-6F2B5A7C8D90"
    public static let advertisedName = "Bandit"
}

// MARK: status

/// The Status characteristic: compact JSON, polled while a dongle screen is visible.
/// Decoding is lenient (missing fields get defaults) so a newer firmware doesn't blank the screen.
public struct DongleStatus: Decodable, Equatable, Sendable {
    public struct Band: Decodable, Equatable, Sendable {
        /// `live`, `connecting`, `searching`, `paused`, `no-owner`.
        public var state: String
        public var battery: Int?
        public var charging: Bool?
        public var hand: String?
        /// The band's own battery voltage and current (negative while charging), firmware 0.10+.
        public var millivolts: Int?
        public var milliamps: Int?

        enum CodingKeys: String, CodingKey { case state = "s", battery = "bat", charging = "chg", hand, millivolts = "mv", milliamps = "ma" }

        public init(state: String, battery: Int? = nil, charging: Bool? = nil, hand: String? = nil, millivolts: Int? = nil, milliamps: Int? = nil) {
            self.state = state
            self.battery = battery
            self.charging = charging
            self.hand = hand
            self.millivolts = millivolts
            self.milliamps = milliamps
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            state = try c.decodeIfPresent(String.self, forKey: .state) ?? "unknown"
            battery = try c.decodeIfPresent(Int.self, forKey: .battery)
            charging = try c.decodeIfPresent(Bool.self, forKey: .charging)
            hand = try c.decodeIfPresent(String.self, forKey: .hand)
            millivolts = try c.decodeIfPresent(Int.self, forKey: .millivolts)
            milliamps = try c.decodeIfPresent(Int.self, forKey: .milliamps)
        }
    }

    public struct Host: Decodable, Equatable, Sendable, Identifiable {
        public var id: Int { handle }
        /// Connection handle, used by `target`, `name` and `forget`.
        public var handle: Int
        /// `phone` (media keys only), `computer` (also keyboard and mouse) or `tv` (keyboard:
        /// arrows, OK, Back).
        public var kind: String
        /// A computer's system: `mac`, `windows` or `linux` (⌘ shortcuts become Ctrl on the last two).
        public var os: String?
        public var name: String
        /// The one host gestures go to.
        public var active: Bool
        /// This host's active profile id (firmware with profiles; nil: unknown).
        public var profile: String?

        enum CodingKeys: String, CodingKey { case handle = "h", kind = "k", os, name = "n", active = "act", profile = "p" }

        public init(handle: Int, kind: String, os: String? = nil, name: String, active: Bool, profile: String? = nil) {
            self.handle = handle
            self.kind = kind
            self.os = os
            self.name = name
            self.active = active
            self.profile = profile
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            handle = try c.decode(Int.self, forKey: .handle)
            kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "phone"
            os = try c.decodeIfPresent(String.self, forKey: .os)
            name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
            active = try c.decodeIfPresent(Bool.self, forKey: .active) ?? false
            profile = try? c.decodeIfPresent(String.self, forKey: .profile)
        }

        public var isComputer: Bool { kind == "computer" }
        public var isTV: Bool { kind == "tv" }

        /// What `kind <h> …` and `pair …` call it.
        public var type: DongleCommand.HostType {
            switch (kind, os) {
            case ("computer", "windows"): .windows
            case ("computer", "linux"): .linux
            case ("computer", _): .mac
            case ("tv", _): .tv
            default: .phone
            }
        }
    }

    public struct Update: Decodable, Equatable, Sendable {
        /// `idle`, `receiving`, `verifying`, `done`, `error`.
        public var state: String
        public var received: Int
        public var total: Int
        public var error: String

        enum CodingKeys: String, CodingKey { case state = "s", received = "got", total = "of", error = "e" }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            state = try c.decodeIfPresent(String.self, forKey: .state) ?? "idle"
            received = try c.decodeIfPresent(Int.self, forKey: .received) ?? 0
            total = try c.decodeIfPresent(Int.self, forKey: .total) ?? 0
            error = try c.decodeIfPresent(String.self, forKey: .error) ?? ""
        }
    }

    public var firmware: String
    /// First 8 hex digits of the running image's ELF SHA-256 (unique per build).
    public var buildID: String
    public var slot: String
    /// True while a fresh update is on probation (a crash before it's confirmed rolls back).
    public var onProbation: Bool
    public var uptime: Int
    public var heap: Int?
    public var band: Band?
    /// The active host's profile id. Before profiles: `media`, `slides`, `write` or `copilot`;
    /// now any id from the dongle's profile set.
    public var mode: String
    /// Seconds left in the pairing window (0 = closed).
    public var pairingSecondsLeft: Int
    /// The connection handle of the host reading this status (the app's own host).
    public var you: Int?
    public var hosts: [Host]
    public var update: Update?
    /// Write mode's air mouse settings (firmware 0.9 and later).
    public var mouse: Mouse?
    /// The stored profile set: `builtin`, or the first 8 hex digits of the SHA-256 of the file
    /// (nil: firmware without profiles).
    public var profileHash: String?
    /// Why the last profile upload was refused (only after one was).
    public var profileError: String?

    public struct Mouse: Decodable, Equatable, Sendable {
        /// 1–10.
        public var speed: Int
        public var flipX: Bool
        public var flipY: Bool
        /// The band's handwriting typed in write mode (off: only the air mouse).
        public var typing: Bool

        enum CodingKeys: String, CodingKey { case speed = "sp", flipX = "fx", flipY = "fy", typing = "ty" }

        public init(speed: Int, flipX: Bool, flipY: Bool, typing: Bool) {
            self.speed = speed
            self.flipX = flipX
            self.flipY = flipY
            self.typing = typing
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            speed = try c.decodeIfPresent(Int.self, forKey: .speed) ?? 5
            flipX = try c.decodeIfPresent(Bool.self, forKey: .flipX) ?? false
            flipY = try c.decodeIfPresent(Bool.self, forKey: .flipY) ?? false
            typing = try c.decodeIfPresent(Bool.self, forKey: .typing) ?? true
        }
    }

    enum CodingKeys: String, CodingKey {
        case firmware = "fw", buildID = "id", slot, onProbation = "verify", uptime = "up", heap, band, mode
        case pairingSecondsLeft = "pair", you, hosts, update = "upd", mouse
        case profileHash = "ph", profileError = "pe"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        firmware = try c.decodeIfPresent(String.self, forKey: .firmware) ?? "?"
        buildID = try c.decodeIfPresent(String.self, forKey: .buildID) ?? ""
        slot = try c.decodeIfPresent(String.self, forKey: .slot) ?? "?"
        onProbation = try c.decodeIfPresent(Bool.self, forKey: .onProbation) ?? false
        uptime = try c.decodeIfPresent(Int.self, forKey: .uptime) ?? 0
        heap = try c.decodeIfPresent(Int.self, forKey: .heap)
        band = try c.decodeIfPresent(Band.self, forKey: .band)
        mode = try c.decodeIfPresent(String.self, forKey: .mode) ?? "media"
        pairingSecondsLeft = try c.decodeIfPresent(Int.self, forKey: .pairingSecondsLeft) ?? 0
        you = try c.decodeIfPresent(Int.self, forKey: .you)
        hosts = try c.decodeIfPresent([Host].self, forKey: .hosts) ?? []
        update = try c.decodeIfPresent(Update.self, forKey: .update)
        mouse = try c.decodeIfPresent(Mouse.self, forKey: .mouse)
        profileHash = try? c.decodeIfPresent(String.self, forKey: .profileHash)?.lowercased()
        profileError = (try? c.decodeIfPresent(String.self, forKey: .profileError)).flatMap { $0.isEmpty ? nil : $0 }
    }

    public static func decode(_ data: Data) throws -> DongleStatus {
        try JSONDecoder().decode(DongleStatus.self, from: data)
    }

    public var activeHost: Host? { hosts.first(where: \.active) }
    /// The firmware keeps gesture profiles (and takes `profile` and `profiles` commands).
    public var supportsProfiles: Bool { profileHash != nil }
}

// MARK: commands

/// Text commands for the Command characteristic (write with response).
public enum DongleCommand: Equatable, Sendable {
    public enum Mode: String, Sendable, CaseIterable { case media, slides, write, copilot }
    public enum MouseFlag: String, Sendable { case flipX = "flipx", flipY = "flipy", typing = "type" }
    public enum PairKind: String, Sendable { case computer, phone }
    /// A host's type. Phones read a media-only report map; the rest read the keyboard and mouse
    /// map, so a host can change type within that group without pairing again.
    public enum HostType: String, Sendable, CaseIterable {
        case phone, mac, windows, linux, tv

        public var label: String {
            switch self {
            case .phone: "Phone"
            case .mac: "Mac"
            case .windows: "Windows"
            case .linux: "Linux"
            case .tv: "TV"
            }
        }

        public var hasKeyboard: Bool { self != .phone }
    }

    case hello(name: String)
    case target(Int)
    case targetNext
    case mode(Mode)
    /// 1–10.
    case mouseSpeed(Int)
    case mouse(MouseFlag, Bool)
    case pair(PairKind)
    case pairType(HostType)
    case pairClose
    case hostType(Int, HostType)
    case name(Int, String)
    case forget(Int)
    case bandPause
    case bandResume
    case key(String)
    case logs
    case reboot
    /// Switch the active host's profile.
    case profile(String)
    case profileNext
    case profilePrevious
    /// Set one host's profile.
    case hostProfile(Int, String)
    /// A profile set upload (`ProfileUpload` builds these).
    case profilesBegin(bytes: Int, sha8: String)
    case profilesData(offset: Int, Data)
    case profilesCommit
    /// Back to the built-in set.
    case profilesReset
    /// The set the dongle runs, as log lines (`ProfileDump` reads them).
    case profilesShow
    case buzz(String)
    case buzzTry(String)
    case lab(Bool)

    /// Keys the firmware knows for `key <name>`.
    public static let keys = ["playpause", "next", "previous", "volup", "voldown", "voice", "phonemute", "teamsmute", "right", "left", "blank"]

    public var text: String {
        switch self {
        case .hello(let name): "hello \(Self.clean(name))"
        case .target(let handle): "target \(handle)"
        case .targetNext: "target next"
        case .mode(let mode): "mode \(mode.rawValue)"
        case .mouseSpeed(let speed): "mouse speed \(min(10, max(1, speed)))"
        case .mouse(let flag, let on): "mouse \(flag.rawValue) \(on ? "on" : "off")"
        case .pair(let kind): "pair \(kind.rawValue)"
        case .pairType(let type): "pair \(type.rawValue)"
        case .hostType(let handle, let type): "kind \(handle) \(type.rawValue)"
        case .pairClose: "pair close"
        case .name(let handle, let name): "name \(handle) \(Self.clean(name))"
        case .forget(let handle): "forget \(handle)"
        case .bandPause: "band pause"
        case .bandResume: "band resume"
        case .key(let key): "key \(key)"
        case .logs: "logs"
        case .reboot: "reboot"
        case .profile(let id): "profile \(Self.word(id))"
        case .profileNext: "profile next"
        case .profilePrevious: "profile previous"
        case .hostProfile(let handle, let id): "profile \(handle) \(Self.word(id))"
        case .profilesBegin(let bytes, let sha8): "profiles begin \(bytes) \(sha8)"
        case .profilesData(let offset, let bytes): "profiles data \(offset) \(bytes.base64EncodedString())"
        case .profilesCommit: "profiles commit"
        case .profilesReset: "profiles reset"
        case .profilesShow: "profiles show"
        case .buzz(let name): "buzz \(Self.word(name))"
        case .buzzTry(let pattern): "buzz try \(pattern.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " "))"
        case .lab(let on): "lab \(on ? "on" : "off")"
        }
    }

    public var data: Data { Data(text.utf8) }

    /// A profile id is one word (valid ids never need this).
    static func word(_ text: String) -> String {
        String(text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.map(Character.init))
    }

    /// Names are one line of at most 32 UTF-8 bytes (cut on a character boundary).
    static func clean(_ name: String) -> String {
        var result = ""
        for character in name.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ").trimmingCharacters(in: .whitespaces) {
            guard result.utf8.count + String(character).utf8.count <= 32 else { break }
            result.append(character)
        }
        return result
    }
}

// MARK: log

/// Reassembles Log notifications (UTF-8 fragments) into lines.
public struct DongleLogAssembler: Sendable {
    private var partial = Data()

    public init() {}

    /// Feeds one notification and returns the lines it completed.
    public mutating func feed(_ fragment: Data) -> [String] {
        partial.append(fragment)
        var lines: [String] = []
        while let newline = partial.firstIndex(of: 0x0A) {
            let line = partial[partial.startIndex..<newline]
            lines.append(String(decoding: line, as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "\r")))
            partial.removeSubrange(partial.startIndex...newline)
        }
        // A runaway line without newlines shouldn't grow forever.
        if partial.count > 4096 {
            lines.append(String(decoding: partial, as: UTF8.self))
            partial.removeAll()
        }
        return lines
    }

    /// Text received after the last newline (shown as the in-progress line).
    public var pending: String { String(decoding: partial, as: UTF8.self) }
}

// MARK: package

/// The 256-byte header of a `.banditfw` package, followed by the ESP32 app image.
public struct DonglePackageHeader: Equatable, Sendable {
    public static let size = 256
    public static let magic: [UInt8] = [0x4E, 0x50, 0x44, 0x46, 0x57, 0x01, 0x00, 0x00] // "NPDFW" 01 00 00

    public let imageLength: Int
    public let version: String
    public let imageSHA256: Data
    public let signature: Data

    public init(_ bytes: Data) throws {
        let bytes = [UInt8](bytes.prefix(Self.size))
        guard bytes.count == Self.size else { throw DonglePackageError.tooShort(bytes.count) }
        guard Array(bytes[0..<8]) == Self.magic else { throw DonglePackageError.badMagic }
        imageLength = Int(UInt32(bytes[8]) | UInt32(bytes[9]) << 8 | UInt32(bytes[10]) << 16 | UInt32(bytes[11]) << 24)
        version = String(decoding: bytes[16..<64].prefix { $0 != 0 }, as: UTF8.self)
        imageSHA256 = Data(bytes[64..<96])
        signature = Data(bytes[96..<160])
    }
}

public enum DonglePackageError: LocalizedError, Equatable, Sendable {
    case tooShort(Int)
    case badMagic
    case lengthMismatch(header: Int, file: Int)
    case sizeMismatch(index: Int, file: Int)
    case checksumMismatch
    case imageChecksumMismatch

    public var errorDescription: String? {
        switch self {
        case .tooShort(let count): "The package is too short (\(count) bytes) to be a dongle firmware package."
        case .badMagic: "This isn't a dongle firmware package (wrong header)."
        case .lengthMismatch(let header, let file): "The package is damaged: its header says \(header + DonglePackageHeader.size) bytes, the file has \(file)."
        case .sizeMismatch(let index, let file): "The download has \(file) bytes, the release index says \(index). Try again."
        case .checksumMismatch: "The download doesn't match the release index's SHA-256. Try again; don't install it."
        case .imageChecksumMismatch: "The firmware image doesn't match the SHA-256 in its own header. Don't install it."
        }
    }
}

/// A downloaded package that passed the app-side checks. The dongle still checks the signature.
public struct DonglePackage: Sendable {
    public let header: DonglePackageHeader
    public let data: Data
    public let sha256: String

    /// Checks the whole file against the release index (SHA-256, size), then the header (magic,
    /// image length + 256 == file size) and the image hash the header carries.
    public init(_ data: Data, expectedSHA256: String, expectedSize: Int? = nil) throws {
        if let expectedSize, expectedSize != data.count { throw DonglePackageError.sizeMismatch(index: expectedSize, file: data.count) }
        let digest = Self.hex(SHA256.hash(data: data))
        guard digest == expectedSHA256.lowercased().trimmingCharacters(in: .whitespaces) else { throw DonglePackageError.checksumMismatch }
        let header = try DonglePackageHeader(data)
        guard header.imageLength + DonglePackageHeader.size == data.count else {
            throw DonglePackageError.lengthMismatch(header: header.imageLength, file: data.count)
        }
        guard Data(SHA256.hash(data: data.dropFirst(DonglePackageHeader.size))) == header.imageSHA256 else {
            throw DonglePackageError.imageChecksumMismatch
        }
        self.header = header
        self.data = data
        sha256 = digest
    }

    static func hex(_ digest: SHA256.Digest) -> String { digest.map { String(format: "%02x", $0) }.joined() }
}

// MARK: release index

/// `latest.json` on the release host (`make release` publishes it; Tailscale serves it at
/// `https://<host>/dongle/`).
public struct DongleRelease: Decodable, Equatable, Sendable {
    /// The index on `host` (e.g. `my-mac.tailnet-name.ts.net`); nil for an empty or bad host.
    public static func indexURL(host: String) -> URL? {
        let host = host.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty, !host.contains("/") else { return nil }
        return URL(string: "https://\(host)/dongle/latest.json")
    }

    public var version: String
    public var id: String
    public var file: String
    public var size: Int?
    public var sha256: String
    public var notes: String?
    public var flasher: String?

    public init(version: String, id: String, file: String, size: Int?, sha256: String, notes: String?, flasher: String?) {
        self.version = version
        self.id = id
        self.file = file
        self.size = size
        self.sha256 = sha256
        self.notes = notes
        self.flasher = flasher
    }

    /// Where the index came from: `file` and `flasher` are relative to it.
    public var index: URL?

    enum CodingKeys: String, CodingKey { case version, id, file, size, sha256, notes, flasher }

    public static func decode(_ data: Data, index: URL) throws -> DongleRelease {
        var release = try JSONDecoder().decode(DongleRelease.self, from: data)
        release.index = index
        return release
    }

    public static func resolve(_ name: String, against index: URL) -> URL? {
        URL(string: name, relativeTo: index)?.absoluteURL
    }

    public var packageURL: URL? { index.flatMap { Self.resolve(file, against: $0) } }
    public var flasherURL: URL? { index.flatMap { index in flasher.flatMap { Self.resolve($0, against: index) } } }

    /// The build IDs are hex prefixes; compare them case-insensitively.
    public func isRunning(on status: DongleStatus) -> Bool { id.lowercased() == status.buildID.lowercased() }
}

// MARK: update stream

/// Notifications on the Update characteristic (dongle → app).
public enum DongleUpdateMessage: Equatable, Sendable {
    case ready
    /// Everything below `next` is committed.
    case ack(next: Int)
    /// A chunk was out of order or dropped: continue from `next`.
    case resend(next: Int)
    /// Verified and the boot slot switched; the dongle reboots in about 1.5 s.
    case done
    case fail(String)

    public init?(_ data: Data) {
        let bytes = [UInt8](data)
        guard let opcode = bytes.first else { return nil }
        switch opcode {
        case 0x80: self = .ready
        case 0x81, 0x82:
            guard bytes.count >= 5 else { return nil }
            let next = Int(UpdateFrame.u32(bytes, at: 1))
            self = opcode == 0x81 ? .ack(next: next) : .resend(next: next)
        case 0x83: self = .done
        case 0x84: self = .fail(String(decoding: bytes.dropFirst(), as: UTF8.self))
        default: return nil
        }
    }
}

/// Writes on the Update characteristic (app → dongle). All integers are u32 little-endian.
public enum UpdateFrame {
    /// Bytes a DATA write spends on its opcode and offset.
    public static let dataOverhead = 5

    public static func begin(total: Int) -> Data { Data([0x01] + le32(total)) }
    public static func data(offset: Int, _ bytes: Data) -> Data { Data([0x02] + le32(offset)) + bytes }
    public static let abort = Data([0x03])

    static func le32(_ value: Int) -> [UInt8] {
        let v = UInt32(truncatingIfNeeded: value)
        return [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24)]
    }

    static func u32(_ bytes: [UInt8], at index: Int) -> UInt32 {
        UInt32(bytes[index]) | UInt32(bytes[index + 1]) << 8 | UInt32(bytes[index + 2]) << 16 | UInt32(bytes[index + 3]) << 24
    }
}

/// The sending side of an update, as a pure state machine: which chunk goes next, the window
/// beyond the last ACK, RESEND, and the no-ACK timeout. The caller supplies the clock.
public struct DongleTransfer: Equatable, Sendable {
    public static let window = 8 * 1024
    public static let ackTimeout: TimeInterval = 5
    /// Timeouts in a row without the ACK moving before the transfer gives up.
    public static let maxStalls = 6

    public let total: Int
    public let chunkSize: Int
    /// Everything below this is committed on the dongle.
    public private(set) var acked = 0
    /// The next offset to send.
    public private(set) var next = 0
    public private(set) var lastProgress: TimeInterval
    public private(set) var stalls = 0
    public private(set) var resends = 0

    public init(total: Int, chunkSize: Int, now: TimeInterval) {
        precondition(total > 0 && chunkSize > 0)
        self.total = total
        self.chunkSize = min(chunkSize, Self.window)
        lastProgress = now
    }

    /// Every byte is committed: what's left is the dongle's verify and DONE (or FAIL).
    public var allAcknowledged: Bool { acked >= total }
    public var inFlight: Int { next - acked }
    public var gaveUp: Bool { stalls >= Self.maxStalls }

    /// The next chunk to send, if the window allows one. Advances `next`.
    public mutating func nextChunk() -> Range<Int>? {
        guard next < total, !gaveUp else { return nil }
        let length = min(chunkSize, total - next)
        guard inFlight + length <= Self.window else { return nil }
        defer { next += length }
        return next..<(next + length)
    }

    public mutating func ack(_ offset: Int, now: TimeInterval) {
        let offset = min(offset, total)
        guard offset > acked else { return }
        acked = offset
        if next < acked { next = acked }
        lastProgress = now
        stalls = 0
    }

    /// The dongle wants everything again from `offset` (it has committed what's below it).
    public mutating func resend(from offset: Int, now: TimeInterval) {
        let offset = min(max(offset, 0), total)
        acked = offset
        next = offset
        lastProgress = now
        resends += 1
    }

    /// No ACK for `ackTimeout`: rewind to the last ACK. Returns true when it rewound.
    public mutating func checkTimeout(now: TimeInterval) -> Bool {
        guard !allAcknowledged, next > acked, now - lastProgress >= Self.ackTimeout else { return false }
        next = acked
        lastProgress = now
        stalls += 1
        resends += 1
        return true
    }
}
