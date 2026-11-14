import CryptoKit
import Foundation

/// Gesture profiles (`np-profiles` JSON, version 1): what each band gesture does on the dongle,
/// per profile and per kind of host. See firmware/np-profiles/PROFILES.md. The checks here are the
/// dongle's own (firmware/np-profiles/src/lib.rs, `RawFile::check`), down to the error paths, so a
/// file the app accepts is one the dongle saves; the shared test vectors keep the two in step.
public enum ProfileFormat {
    public static let format = "np-profiles"
    public static let version: Int64 = 1
    /// The largest file the dongle keeps, minified.
    public static let maxBytes = 6144
    public static let maxProfiles = 12
    /// Apps one profile may list.
    public static let maxApps = 16
    /// `write` with no time: handwriting stops after this many seconds with nothing written.
    public static let writeSeconds = 10
    public static let fileExtension = "npprofiles"
    public static let typeIdentifier = "dev.neuralplayground.profiles"
    /// Status `ph` while the dongle runs its built-in set.
    public static let builtinHash = "builtin"

    /// The first 8 lowercase hex digits of the SHA-256 of `data` (status `ph`, `profiles begin`).
    public static func sha8(_ data: Data) -> String {
        SHA256.hash(data: data).prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    /// The dongle's verdict on a file, or nil when it would save it. The size limit applies to the
    /// minified form, which is what the app sends.
    public static func validate(_ data: Data) -> ProfileError? {
        do {
            _ = try check(data)
            return nil
        } catch {
            return error as? ProfileError ?? ProfileError("", error.localizedDescription)
        }
    }

    public static func check(_ data: Data) throws -> ParsedProfileSet {
        try check(parse(data))
    }

    /// JSON text → a document, with the dongle's wording for broken files.
    public static func parse(_ data: Data) throws -> JSONValue {
        do {
            return try JSONValue.parse(data)
        } catch let error as JSONParseError {
            throw ProfileError("", "not np-profiles JSON: \(error)")
        }
    }

    public static func check(_ value: JSONValue) throws -> ParsedProfileSet {
        let size = value.minified.utf8.count
        if size > maxBytes { throw ProfileError("", "\(size) bytes is too big (at most \(maxBytes), minified)") }
        return try RawFile(value).check()
    }
}

/// A problem with a file, and where (`profiles[2].gestures.swipe.up`; empty for the whole file).
public struct ProfileError: Error, Equatable, Sendable, CustomStringConvertible, LocalizedError {
    public let path: String
    public let message: String

    public init(_ path: String, _ message: String) {
        self.path = path
        self.message = message
    }

    public var description: String { path.isEmpty ? message : "\(path): \(message)" }
    public var errorDescription: String? { description }
}

// MARK: vocabulary

/// Kinds of host a file names: `computer` is any of the three computers.
public enum ProfileHosts: String, CaseIterable, Sendable {
    case phone, computer, mac, windows, linux, tv

    public func matches(_ type: DongleCommand.HostType) -> Bool {
        switch self {
        case .phone: type == .phone
        case .computer: type == .mac || type == .windows || type == .linux
        case .mac: type == .mac
        case .windows: type == .windows
        case .linux: type == .linux
        case .tv: type == .tv
        }
    }

    /// Exact kinds win over `computer` when one binding names both.
    var isSpecific: Bool { self != .computer }
}

/// Everything a profile can bind.
public struct ProfileGesture: RawRepresentable, Hashable, CaseIterable, Sendable {
    public let rawValue: String
    private init(_ name: String) { rawValue = name }
    public init?(rawValue: String) {
        guard Self.allCases.contains(where: { $0.rawValue == rawValue }) else { return nil }
        self.rawValue = rawValue
    }
    public static let indexTap = Self("index.tap")
    public static let indexDoubleTap = Self("index.doubleTap")
    public static let indexTripleTap = Self("index.tripleTap")
    public static let indexHold = Self("index.hold")
    public static let middleTap = Self("middle.tap")
    public static let middleDoubleTap = Self("middle.doubleTap")
    public static let middleTripleTap = Self("middle.tripleTap")
    public static let middleHold = Self("middle.hold")
    public static let swipeUp = Self("swipe.up")
    public static let swipeDown = Self("swipe.down")
    public static let swipeLeft = Self("swipe.left")
    public static let swipeRight = Self("swipe.right")
    public static let dialCW = Self("dial.cw")
    public static let dialCCW = Self("dial.ccw")
    public static let flickUp = Self("flick.up")
    public static let flickDown = Self("flick.down")
    public static let flickLeft = Self("flick.left")
    public static let flickRight = Self("flick.right")
    public static let named: [Self] = [.indexTap, .indexDoubleTap, .indexTripleTap, .indexHold, .middleTap, .middleDoubleTap, .middleTripleTap, .middleHold, .swipeUp, .swipeDown, .swipeLeft, .swipeRight, .dialCW, .dialCCW, .flickUp, .flickDown, .flickLeft, .flickRight]
    public static let bandFingers = ["thumb", "index", "middle"]
    public static let bandEvents = ["press", "release", "tap", "doubletap", "click", "up", "down", "left", "right", "wake", "swipeIn", "swipeOut", "ia", "partialPress", "partialRelease", "partialClick", "partialUp", "partialDown", "partialLeft", "partialRight", "singleTap", "doubleTap", "buttonHold", "buttonRelease", "buttonUp", "buttonDown", "buttonLeft", "buttonRight", "buttonPress", "buttonHoldRelease"]
    public static let band: [Self] = ([""] + bandFingers).flatMap { finger in
        bandEvents.map { Self("band." + (finger.isEmpty ? "" : finger + ".") + $0) }
    }
    public static let allCases = named + band
    public var requiresNewFirmware: Bool { rawValue.hasPrefix("flick.") || rawValue.hasPrefix("band.") }
}

public enum MediaKey: String, CaseIterable, Sendable {
    case playPause, next, previous, volumeUp, volumeDown, mute, voice
}

public enum MouseButton: String, Sendable {
    case left = "click", right = "rightClick", middle = "middleClick"
}

/// A key with modifiers as HID usages (keyboard page 0x07). `cmd` is GUI: the dongle sends it as
/// Ctrl to Windows and Linux.
public struct Chord: Equatable, Sendable {
    public static let ctrl: UInt8 = 0x01
    public static let shift: UInt8 = 0x02
    public static let alt: UInt8 = 0x04
    public static let gui: UInt8 = 0x08

    public var modifiers: UInt8
    public var usage: UInt8

    public init(modifiers: UInt8, usage: UInt8) {
        self.modifiers = modifiers
        self.usage = usage
    }
}

public enum ProfileTarget: Equatable, Sendable {
    case id(String), next, previous
}

public enum HostTarget: Equatable, Sendable {
    case next, previous, kind(ProfileHosts)
}

/// A call on an iPhone (its notifications' buttons, through ANCS).
public enum CallAction: String, CaseIterable, Sendable {
    /// Answers the ringing call.
    case answer
    /// Declines the ringing call, else hangs up the one in progress.
    case end

    public var title: String {
        switch self {
        case .answer: "Answer the call"
        case .end: "Decline or hang up"
        }
    }
}

/// One action, read (`media:playPause`, `key:cmd+shift+m`, `profile:write`, …).
public enum ProfileAction: Equatable, Sendable {
    /// Explicitly nothing (a host-specific "none" beats the binding's default).
    case none
    case media(MediaKey)
    /// The headset phone-mute button (phones).
    case phoneMute
    /// A call on an iPhone.
    case call(CallAction)
    case key(Chord)
    /// Pressed while `middle.hold` lasts, released with it.
    case hold(Chord)
    case type(String)
    case click(MouseButton)
    /// Wheel steps, up positive.
    case scroll(Int)
    case profile(ProfileTarget)
    case host(HostTarget)
    /// The letter menu.
    case menu
    /// Handwriting on, typed on the host, until nothing is written for this many seconds.
    case write(Int)
    case buzz(Pattern)
    case apps(Bool)
}

// MARK: the checked set

/// A file the dongle would accept, read: what `ProfileSet::parse` returns in the firmware.
public struct ParsedProfileSet: Equatable, Sendable {
    public struct Binding: Equatable, Sendable {
        public var defaultAction: ProfileAction?
        public var variants: [(hosts: ProfileHosts, action: ProfileAction)]
        public var buzz: Pattern? = nil

        public static func == (a: Binding, b: Binding) -> Bool {
            a.buzz == b.buzz && a.defaultAction == b.defaultAction && a.variants.elementsEqual(b.variants) { $0.hosts == $1.hosts && $0.action == $1.action }
        }

        /// An exact kind's variant, then `computer`'s, then the default; `none` is no action.
        public func resolve(_ type: DongleCommand.HostType) -> ProfileAction? {
            func pick(_ specific: Bool) -> ProfileAction? {
                variants.first { $0.hosts.isSpecific == specific && $0.hosts.matches(type) }?.action
            }
            let action = pick(true) ?? pick(false) ?? defaultAction
            return action == ProfileAction.none ? nil : action
        }
    }

    public struct Profile: Equatable, Sendable {
        public var id: String
        public var name: String
        public var buzz: Pattern
        /// Empty: everyone.
        public var hosts: [ProfileHosts]
        public var typing: Bool
        public var pointer: Bool
        public var gestures: [ProfileGesture: Binding]
        /// Mac bundle ids that switch a computer to it while they're in front.
        public var apps: [String] = []

        public func allows(_ type: DongleCommand.HostType) -> Bool { hosts.isEmpty || hosts.contains { $0.matches(type) } }
        public func action(_ gesture: ProfileGesture, for type: DongleCommand.HostType) -> ProfileAction? { gestures[gesture]?.resolve(type) }
    }

    public var name: String
    public var profiles: [Profile]
    public var menu: [String: ProfileAction]
    /// Start profile ids for phone, computer and tv.
    public var start: [String]
    public var buzzes: [String: Pattern] = [:]
    public var feedback: [String: Pattern] = [:]

    public func startProfile(for type: DongleCommand.HostType) -> String {
        start[type == .phone ? 0 : type == .tv ? 2 : 1]
    }
}

// MARK: reading a file the way serde does

/// The fields `RawFile` reads, with serde's rules: unknown fields are ignored, a missing optional
/// field gets its default, a wrong type (null included) fails the whole file (path "").
private struct RawFile {
    struct Profile {
        var id: String
        var name: String
        var buzz: JSONValue
        var hosts: [String]
        var typing: Bool
        var pointer: Bool
        var gestures: JSONObject
        var apps: [String]
    }

    var format: String
    var version: Int64
    var name: String
    var menu: JSONObject
    var start: JSONObject
    var profiles: [Profile]
    var buzzes: JSONObject
    var feedback: JSONObject

    static func invalid(_ message: String) -> ProfileError { ProfileError("", "not np-profiles JSON: \(message)") }

    /// The struct's own fields, once each.
    static func fields(_ value: JSONValue, _ known: [String], what: String) throws -> [String: JSONValue] {
        guard let object = value.object else { throw invalid("invalid type: \(value.typeName), expected \(what)") }
        var fields: [String: JSONValue] = [:]
        for member in object.members where known.contains(member.key) {
            if fields[member.key] != nil { throw invalid("duplicate field `\(member.key)`") }
            fields[member.key] = member.value
        }
        return fields
    }

    static func string(_ value: JSONValue?, _ field: String, default fallback: String? = nil) throws -> String {
        guard let value else {
            if let fallback { return fallback }
            throw invalid("missing field `\(field)`")
        }
        guard let text = value.string else { throw invalid("invalid type: \(value.typeName), expected a string (`\(field)`)") }
        return text
    }

    static func bool(_ value: JSONValue?, _ field: String) throws -> Bool {
        guard let value else { return false }
        guard let flag = value.bool else { throw invalid("invalid type: \(value.typeName), expected a boolean (`\(field)`)") }
        return flag
    }

    /// A map whose values are strings (menu, start).
    static func stringMap(_ value: JSONValue?, _ field: String) throws -> JSONObject {
        guard let value else { return JSONObject() }
        guard let object = value.object else { throw invalid("invalid type: \(value.typeName), expected a map (`\(field)`)") }
        for member in object.members where member.value.string == nil {
            throw invalid("invalid type: \(member.value.typeName), expected a string (`\(field).\(member.key)`)")
        }
        return object
    }

    init(_ value: JSONValue) throws {
        let fields = try Self.fields(value, ["format", "version", "name", "menu", "start", "profiles", "buzzes", "feedback"], what: "an np-profiles object")
        format = try Self.string(fields["format"], "format")
        guard let versionValue = fields["version"] else { throw Self.invalid("missing field `version`") }
        guard let version = versionValue.integer, version >= 0 else {
            throw Self.invalid("invalid type: \(versionValue.typeName), expected u64 (`version`)")
        }
        self.version = version
        name = try Self.string(fields["name"], "name", default: "")
        menu = try Self.stringMap(fields["menu"], "menu")
        start = try Self.stringMap(fields["start"], "start")
        buzzes = try Self.stringMap(fields["buzzes"], "buzzes")
        feedback = try Self.stringMap(fields["feedback"], "feedback")
        guard let list = fields["profiles"] else { throw Self.invalid("missing field `profiles`") }
        guard let items = list.array else { throw Self.invalid("invalid type: \(list.typeName), expected a sequence (`profiles`)") }
        profiles = try items.map { item in
            let fields = try Self.fields(item, ["id", "name", "buzz", "hosts", "typing", "pointer", "gestures", "apps"], what: "a profile")
            let buzz = fields["buzz"] ?? .null
            var hosts: [String] = []
            if let value = fields["hosts"] {
                guard let list = value.array else { throw Self.invalid("invalid type: \(value.typeName), expected a sequence (`hosts`)") }
                hosts = try list.map { try Self.string($0, "hosts") }
            }
            var apps: [String] = []
            if let value = fields["apps"] {
                guard let list = value.array else { throw Self.invalid("invalid type: \(value.typeName), expected a sequence (`apps`)") }
                apps = try list.map { try Self.string($0, "apps") }
            }
            var gestures = JSONObject()
            if let value = fields["gestures"] {
                guard let object = value.object else { throw Self.invalid("invalid type: \(value.typeName), expected a map (`gestures`)") }
                gestures = object
            }
            return Profile(id: try Self.string(fields["id"], "id"), name: try Self.string(fields["name"], "name"), buzz: buzz, hosts: hosts,
                           typing: try Self.bool(fields["typing"], "typing"), pointer: try Self.bool(fields["pointer"], "pointer"), gestures: gestures, apps: apps)
        }
    }

    /// `RawFile::check`, rule for rule and in the same order.
    func check() throws -> ParsedProfileSet {
        let F = ProfileFormat.self
        if format != F.format { throw ProfileError("format", "must be \"\(F.format)\"") }
        if version != F.version { throw ProfileError("version", "\(version) isn't supported (this dongle reads version \(F.version))") }
        if name.unicodeScalars.count > 40 { throw ProfileError("name", "at most 40 characters") }
        if profiles.isEmpty || profiles.count > F.maxProfiles { throw ProfileError("profiles", "1 to \(F.maxProfiles) profiles") }
        if buzzes.sortedUnique.count > 16 { throw ProfileError("buzzes", "at most 16 buzz patterns") }
        var patterns: [String: Pattern] = [:]
        for member in buzzes.sortedUnique {
            let path = "buzzes.\(member.key)"
            if !F.isValidID(member.key) { throw ProfileError(path, "a pattern's name is 1–16 of a–z, 0–9 and -") }
            if member.key == "none" { throw ProfileError(path, "\"none\" means no buzz: pick another name") }
            patterns[member.key] = try F.parsePattern(member.value.string!, path: path)
        }
        let ids = profiles.map(\.id)
        var parsed: [ParsedProfileSet.Profile] = []
        for (i, raw) in profiles.enumerated() {
            let at = "profiles[\(i)]"
            if !F.isValidID(raw.id) { throw ProfileError("\(at).id", "1–16 of a–z, 0–9 and -") }
            if ids[..<i].contains(raw.id) { throw ProfileError("\(at).id", "\"\(raw.id)\" is used twice") }
            let nameLength = raw.name.unicodeScalars.count
            if nameLength == 0 || nameLength > 24 { throw ProfileError("\(at).name", "1–24 characters") }
            let buzz: Pattern
            switch raw.buzz {
            case .null: buzz = try F.findBuzz("tap", buzzes: patterns, path: "\(at).buzz")
            case .string(let name): buzz = try F.findBuzz(name, buzzes: patterns, path: "\(at).buzz")
            case .integer, .number:
                guard let n = raw.buzz.integer, (1...4).contains(n) else { throw ProfileError("\(at).buzz", "1–4 buzzes") }
                buzz = try F.findBuzz(["tap", "double", "triple", "quad"][Int(n)-1], buzzes: patterns, path: "\(at).buzz")
            default: throw ProfileError("\(at).buzz", "1–4 buzzes, or a pattern's name")
            }
            var hosts: [ProfileHosts] = []
            for (j, name) in raw.hosts.enumerated() {
                guard let host = ProfileHosts(rawValue: name) else { throw ProfileError("\(at).hosts[\(j)]", F.unknownHosts(name)) }
                hosts.append(host)
            }
            if raw.apps.count > F.maxApps { throw ProfileError("\(at).apps", "at most \(F.maxApps) apps") }
            for (j, app) in raw.apps.enumerated() {
                let path = "\(at).apps[\(j)]"
                if !F.isValidApp(app) { throw ProfileError(path, "an app is 1–64 of A–Z, a–z, 0–9, . _ and - (a Mac bundle id, like com.google.Chrome)") }
                let earlier = profiles[..<i].flatMap(\.apps) + raw.apps[..<j]
                if earlier.contains(where: { $0.lowercased() == app.lowercased() }) { throw ProfileError(path, "\"\(app)\" is listed twice") }
            }
            let computer = hosts.isEmpty || hosts.contains { host in [.mac, .windows, .linux].contains { host.matches($0) } }
            if !raw.apps.isEmpty && !computer { throw ProfileError("\(at).apps", "apps are for computers, and this profile isn't") }
            var gestures: [ProfileGesture: ParsedProfileSet.Binding] = [:]
            for member in raw.gestures.sortedUnique {
                let path = "\(at).gestures.\(member.key)"
                guard let gesture = ProfileGesture(rawValue: member.key) else {
                    throw ProfileError(path, "unknown gesture (one of \(ProfileGesture.named.map(\.rawValue).joined(separator: ", ")), or band.<event> / band.<finger>.<event>)")
                }
                gestures[gesture] = try F.parseBinding(member.value, gesture: gesture, ids: ids, path: path, buzzes: patterns)
            }
            parsed.append(.init(id: raw.id, name: raw.name, buzz: buzz, hosts: hosts, typing: raw.typing, pointer: raw.pointer, gestures: gestures, apps: raw.apps))
        }
        var menu: [String: ProfileAction] = [:]
        for member in self.menu.sortedUnique {
            let path = "menu.\(member.key)"
            let scalars = Array(member.key.unicodeScalars)
            guard scalars.count == 1, let letter = scalars.first else { throw ProfileError(path, "a menu key is one letter or digit") }
            guard ("a"..."z").contains(letter) || ("0"..."9").contains(letter) else { throw ProfileError(path, "a menu key is a–z or 0–9") }
            let action = try F.parseAction(member.value.string ?? "", ids: ids, path: path, buzzes: patterns)
            switch action {
            case .hold, .menu: throw ProfileError(path, "the menu can't hold a key or open itself")
            default: menu[member.key] = action
            }
        }
        var start = ["", "", ""]
        for (slot, type, group) in [(0, DongleCommand.HostType.phone, "phone"), (1, .mac, "computer"), (2, .tv, "tv")] {
            let path = "start.\(group)"
            let index: Int
            if let id = self.start[group]?.string {
                guard let found = ids.firstIndex(of: id) else { throw ProfileError(path, "no profile \"\(id)\"") }
                index = found
            } else {
                guard let found = parsed.firstIndex(where: { $0.allows(type) }) else { throw ProfileError(path, "no profile allows a \(group)") }
                index = found
            }
            let profile = parsed[index]
            let allowed = group == "computer" ? [.mac, .windows, .linux].allSatisfy { profile.allows($0) } : profile.allows(type)
            if !allowed { throw ProfileError(path, "\"\(profile.id)\" isn't for a \(group)") }
            start[slot] = profile.id
        }
        for member in self.start.sortedUnique where !["phone", "computer", "tv"].contains(member.key) {
            throw ProfileError("start.\(member.key)", "start is for phone, computer and tv")
        }
        var resolved: [String: Pattern] = [:]
        for member in feedback.sortedUnique {
            let path = "feedback.\(member.key)"
            guard BuzzFeedback.all.contains(where: { $0.name == member.key }) else {
                throw ProfileError(path, "unknown moment (one of \(BuzzFeedback.all.map(\.name).joined(separator: ", ")))")
            }
            if member.value.string != "none" { resolved[member.key] = try F.findBuzz(member.value.string!, buzzes: patterns, path: path) }
        }
        for moment in BuzzFeedback.all where feedback[moment.name] == nil && moment.pattern != "none" {
            resolved[moment.name] = try F.findBuzz(moment.pattern, buzzes: patterns, path: "feedback.\(moment.name)")
        }
        return ParsedProfileSet(name: name, profiles: parsed, menu: menu, start: start, buzzes: patterns, feedback: resolved)
    }
}

// MARK: bindings, actions, chords

extension ProfileFormat {
    /// 1–16 of a–z, 0–9 and `-`.
    /// 1–64 of A–Z, a–z, 0–9, `.`, `_` and `-`: a Mac bundle id.
    public static func isValidApp(_ app: String) -> Bool {
        (1...64).contains(app.utf8.count)
            && app.utf8.allSatisfy { (0x41...0x5A).contains($0) || (0x61...0x7A).contains($0) || (0x30...0x39).contains($0) || "._-".utf8.contains($0) }
    }

    public static func isValidID(_ id: String) -> Bool {
        (1...16).contains(id.utf8.count) && id.utf8.allSatisfy { (0x61...0x7A).contains($0) || (0x30...0x39).contains($0) || $0 == 0x2D }
    }

    static func unknownHosts(_ name: String) -> String {
        "unknown host kind \"\(name)\" (one of \(ProfileHosts.allCases.map(\.rawValue).joined(separator: ", ")))"
    }

    static func parseBinding(_ value: JSONValue, gesture: ProfileGesture, ids: [String], path: String, buzzes: [String: Pattern] = [:]) throws -> ParsedProfileSet.Binding {
        func action(_ value: JSONValue, _ path: String) throws -> ProfileAction {
            guard let text = value.string else { throw ProfileError(path, "an action is a string, like \"media:playPause\"") }
            let action = try parseAction(text, ids: ids, path: path, buzzes: buzzes)
            if case .hold = action, gesture != .middleHold {
                throw ProfileError(path, "hold: only works on middle.hold (it's released with the finger)")
            }
            return action
        }
        switch value {
        case .string:
            return .init(defaultAction: try action(value, path), variants: [])
        case .object(let object):
            var binding = ParsedProfileSet.Binding(defaultAction: nil, variants: [])
            for member in object.sortedUnique {
                let path = "\(path).\(member.key)"
                if member.key == "default" {
                    binding.defaultAction = try action(member.value, path)
                } else if member.key == "buzz" {
                    guard let name = member.value.string else { throw ProfileError(path, "a buzz is a pattern's name, like \"tick\"") }
                    binding.buzz = try findBuzz(name, buzzes: buzzes, path: path)
                } else {
                    guard let hosts = ProfileHosts(rawValue: member.key) else { throw ProfileError(path, unknownHosts(member.key)) }
                    binding.variants.append((hosts, try action(member.value, path)))
                }
            }
            return binding
        default:
            throw ProfileError(path, "an action string, or an object of them by host kind (\"phone\", \"computer\", \"tv\", …, \"default\", and \"buzz\")")
        }
    }

    /// Splits at the first `separator` byte (ASCII, so never inside a character).
    static func splitOnce(_ text: String, _ separator: UInt8) -> (String, String)? {
        let bytes = Array(text.utf8)
        guard let at = bytes.firstIndex(of: separator) else { return nil }
        return (String(decoding: bytes[..<at], as: UTF8.self), String(decoding: bytes[(at + 1)...], as: UTF8.self))
    }

    /// One action (PROFILES.md lists them). `ids` are the file's profile ids, for `profile:<id>`.
    public static func parseAction(_ text: String, ids: [String], path: String, buzzes: [String: Pattern] = [:]) throws -> ProfileAction {
        func fail(_ message: String) -> ProfileError { ProfileError(path, message) }
        let (kind, arg) = splitOnce(text, UInt8(ascii: ":")) ?? (text, "")
        switch kind {
        case "none" where arg.isEmpty: return .none
        case "menu" where arg.isEmpty: return .menu
        case "write":
            if arg.isEmpty { return .write(ProfileFormat.writeSeconds) }
            guard let seconds = UInt8(arg), (3...60).contains(seconds) else { throw fail("write: stops after 3–60 s with nothing written") }
            return .write(Int(seconds))
        case "phoneMute" where arg.isEmpty: return .phoneMute
        case "call":
            guard let call = CallAction(rawValue: arg) else { throw fail("unknown call action \"\(arg)\" (call:answer, call:end)") }
            return .call(call)
        case "media":
            guard let key = MediaKey(rawValue: arg) else {
                throw fail("unknown media key \"\(arg)\" (one of \(MediaKey.allCases.map(\.rawValue).joined(separator: ", ")))")
            }
            return .media(key)
        case "key", "hold":
            switch parseChord(arg) {
            case .success(let chord): return kind == "key" ? .key(chord) : .hold(chord)
            case .failure(let error): throw fail(error.message)
            }
        case "type":
            if arg.isEmpty || arg.utf8.count > 64 || !arg.utf8.allSatisfy({ (0x20..<0x7F).contains($0) }) {
                throw fail("type: is 1–64 printable ASCII characters")
            }
            return .type(arg)
        case "mouse":
            let (what, count) = splitOnce(arg, UInt8(ascii: ":")) ?? (arg, "")
            var steps = 4
            if !count.isEmpty {
                guard let n = Int8(count), (1...20).contains(n) else { throw fail("scroll steps are 1–20") }
                steps = Int(n)
            }
            switch what {
            case "click" where count.isEmpty: return .click(.left)
            case "rightClick" where count.isEmpty: return .click(.right)
            case "middleClick" where count.isEmpty: return .click(.middle)
            case "scrollUp": return .scroll(steps)
            case "scrollDown": return .scroll(-steps)
            default: throw fail("unknown mouse action \"\(arg)\" (click, rightClick, middleClick, scrollUp[:n], scrollDown[:n])")
            }
        case "profile":
            switch arg {
            case "next": return .profile(.next)
            case "previous": return .profile(.previous)
            default:
                guard ids.contains(arg) else { throw fail("no profile \"\(arg)\"") }
                return .profile(.id(arg))
            }
        case "host":
            switch arg {
            case "next": return .host(.next)
            case "previous": return .host(.previous)
            default:
                guard let hosts = ProfileHosts(rawValue: arg) else {
                    throw fail("host:next, host:previous or a kind (\(ProfileHosts.allCases.map(\.rawValue).joined(separator: ", ")))")
                }
                return .host(.kind(hosts))
            }
        case "buzz": return .buzz(try findBuzz(arg, buzzes: buzzes, path: path))
        case "apps":
            guard arg == "next" || arg == "previous" else { throw fail("unknown apps action \"\(arg)\" (apps:next, apps:previous)") }
            return .apps(arg == "next")
        default:
            throw fail("unknown action \"\(text)\" (none, menu, write, phoneMute, call:, media:, key:, hold:, type:, mouse:, profile:, host:, buzz:, apps:)")
        }
    }

    public struct ChordError: Error, Equatable, Sendable {
        public let message: String
    }

    /// `cmd+shift+m`, `ctrl+alt+delete`, `f5`, `]`: modifiers, then one key.
    public static func parseChord(_ text: String) -> Result<Chord, ChordError> {
        if text.isEmpty { return .failure(ChordError(message: "a key, like key:enter or key:cmd+shift+m")) }
        let bytes = Array(text.utf8)
        let plus = UInt8(ascii: "+")
        // "+" alone is the plus key; "cmd++" is ⌘ and plus.
        let modifierText: String
        let key: String
        if bytes.count >= 2, bytes[bytes.count - 1] == plus, bytes[bytes.count - 2] == plus {
            modifierText = String(decoding: bytes[..<(bytes.count - 2)], as: UTF8.self)
            key = "+"
        } else if let at = bytes.lastIndex(of: plus), at < bytes.count - 1 {
            modifierText = String(decoding: bytes[..<at], as: UTF8.self)
            key = String(decoding: bytes[(at + 1)...], as: UTF8.self)
        } else {
            modifierText = ""
            key = text
        }
        var modifiers: UInt8 = 0
        if !modifierText.isEmpty {
            for name in Array(modifierText.utf8).split(separator: plus, omittingEmptySubsequences: false) {
                let lower = asciiLowercased(String(decoding: name, as: UTF8.self))
                switch lower {
                case "cmd", "command", "gui", "win", "super", "meta": modifiers |= Chord.gui
                case "ctrl", "control": modifiers |= Chord.ctrl
                case "alt", "option", "opt": modifiers |= Chord.alt
                case "shift": modifiers |= Chord.shift
                default: return .failure(ChordError(message: "unknown modifier \"\(lower)\" (cmd, ctrl, alt, shift)"))
                }
            }
        }
        guard let (shift, usage) = keyUsage(key) else {
            return .failure(ChordError(message: "unknown key \"\(key)\" (PROFILES.md lists the names)"))
        }
        return .success(Chord(modifiers: modifiers | (shift ? Chord.shift : 0), usage: usage))
    }

    static func asciiLowercased(_ text: String) -> String {
        String(decoding: text.utf8.map { (0x41...0x5A).contains($0) ? $0 + 0x20 : $0 }, as: UTF8.self)
    }

    /// A key name or character → (needs shift, HID usage), US layout.
    public static func keyUsage(_ name: String) -> (shift: Bool, usage: UInt8)? {
        let lower = asciiLowercased(name)
        let named: UInt8? = switch lower {
        case "enter", "return": 0x28
        case "escape", "esc": 0x29
        case "backspace": 0x2A
        case "tab": 0x2B
        case "space": 0x2C
        case "minus": 0x2D
        case "equal", "equals": 0x2E
        case "capslock": 0x39
        case "right": 0x4F
        case "left": 0x50
        case "down": 0x51
        case "up": 0x52
        case "home": 0x4A
        case "pageup": 0x4B
        case "delete", "forwarddelete": 0x4C
        case "end": 0x4D
        case "pagedown": 0x4E
        case "insert": 0x49
        case "printscreen": 0x46
        case "menu", "application": 0x65
        default: nil
        }
        if let named { return (false, named) }
        if lower.utf8.first == UInt8(ascii: "f"), let n = UInt8(String(decoding: lower.utf8.dropFirst(), as: UTF8.self)), (1...12).contains(n) {
            return (false, 0x3A + n - 1)
        }
        let scalars = Array(name.unicodeScalars)
        guard scalars.count == 1 else { return nil }
        return charUsage(scalars[0])
    }

    /// One character → (needs shift, HID usage), US layout.
    public static func charUsage(_ c: Unicode.Scalar) -> (shift: Bool, usage: UInt8)? {
        let v = c.value
        switch c {
        case "a"..."z": return (false, 0x04 + UInt8(v - 0x61))
        case "A"..."Z": return (true, 0x04 + UInt8(v - 0x41))
        case "1"..."9": return (false, 0x1E + UInt8(v - 0x31))
        case "0": return (false, 0x27)
        case " ": return (false, 0x2C)
        default: break
        }
        return symbolUsages[c].map { (shift: $0.0, usage: $0.1) }
    }

    static let symbolUsages: [Unicode.Scalar: (Bool, UInt8)] = [
        "-": (false, 0x2D), "_": (true, 0x2D), "=": (false, 0x2E), "+": (true, 0x2E),
        "[": (false, 0x2F), "{": (true, 0x2F), "]": (false, 0x30), "}": (true, 0x30),
        "\\": (false, 0x31), "|": (true, 0x31), ";": (false, 0x33), ":": (true, 0x33),
        "'": (false, 0x34), "\"": (true, 0x34), "`": (false, 0x35), "~": (true, 0x35),
        ",": (false, 0x36), "<": (true, 0x36), ".": (false, 0x37), ">": (true, 0x37),
        "/": (false, 0x38), "?": (true, 0x38),
        "!": (true, 0x1E), "@": (true, 0x1F), "#": (true, 0x20), "$": (true, 0x21), "%": (true, 0x22),
        "^": (true, 0x23), "&": (true, 0x24), "*": (true, 0x25), "(": (true, 0x26), ")": (true, 0x27),
    ]
}

// MARK: the editable file

/// A profile set as the app edits it: the file's own strings (actions stay text, so an unfinished
/// one can be shown and fixed), plus whatever else the file had. Written back in a stable order
/// (`json`), so the same set always hashes the same.
public struct GestureProfileSet: Equatable, Sendable {
    public var format: String
    public var version: Int64
    public var name: String?
    /// Letter or digit → action.
    public var menu: [String: String]
    /// `phone`, `computer`, `tv` → profile id.
    public var start: [String: String]
    public var profiles: [GestureProfile]
    public var buzzes: [String: String] = [:]
    public var feedback: [String: String] = [:]
    /// Top-level fields this app doesn't know, in file order.
    public var extra: JSONObject

    public init(name: String? = nil, menu: [String: String] = [:], start: [String: String] = [:], profiles: [GestureProfile], extra: JSONObject = JSONObject()) {
        format = ProfileFormat.format
        version = ProfileFormat.version
        self.name = name
        self.menu = menu
        self.start = start
        self.profiles = profiles
        self.extra = extra
    }

    public static let startGroups = ["phone", "computer", "tv"]

    // MARK: reading

    public static func decode(_ data: Data) throws -> GestureProfileSet { try GestureProfileSet(json: ProfileFormat.parse(data)) }

    /// Reads any file shaped like a profile set, valid or not (`validate()` says which).
    public init(json: JSONValue) throws {
        guard let object = json.object else { throw ProfileError("", "not np-profiles JSON: the file is \(json.typeName), not an object") }
        format = ""
        version = 0
        menu = [:]
        start = [:]
        profiles = []
        extra = JSONObject()
        var sawProfiles = false
        for member in object.members {
            let value = member.value
            switch member.key {
            case "format": format = try Self.string(value, member.key)
            case "version":
                guard let number = value.integer else { throw ProfileError("version", "a whole number") }
                version = number
            case "name": name = try Self.string(value, member.key)
            case "buzzes": buzzes = try Self.strings(value, member.key)
            case "feedback": feedback = try Self.strings(value, member.key)
            case "menu": menu = try Self.strings(value, member.key)
            case "start": start = try Self.strings(value, member.key)
            case "profiles":
                guard let list = value.array else { throw ProfileError("profiles", "a list of profiles") }
                profiles = try list.enumerated().map { try GestureProfile(json: $1, path: "profiles[\($0)]") }
                sawProfiles = true
            default: extra.append(member.key, value)
            }
        }
        if !sawProfiles { throw ProfileError("profiles", "the file has no profiles") }
    }

    static func string(_ value: JSONValue, _ path: String) throws -> String {
        guard let text = value.string else { throw ProfileError(path, "a string") }
        return text
    }

    static func strings(_ value: JSONValue, _ path: String) throws -> [String: String] {
        guard let object = value.object else { throw ProfileError(path, "an object of strings") }
        var map: [String: String] = [:]
        for member in object.members { map[member.key] = try string(member.value, "\(path).\(member.key)") }
        return map
    }

    // MARK: writing

    public var json: JSONValue {
        var object = JSONObject()
        object.append("format", .string(format))
        object.append("version", .integer(version))
        if let name { object.append("name", .string(name)) }
        if !menu.isEmpty {
            object.append("menu", .object(JSONObject(menu.keys.sorted(by: JSONObject.byteOrder).map { .init($0, .string(menu[$0]!)) })))
        }
        if !start.isEmpty {
            let keys = Self.startGroups.filter { start[$0] != nil } + start.keys.filter { !Self.startGroups.contains($0) }.sorted(by: JSONObject.byteOrder)
            object.append("start", .object(JSONObject(keys.map { .init($0, .string(start[$0]!)) })))
        }
        for (key, map) in [("buzzes", buzzes), ("feedback", feedback)] where !map.isEmpty {
            object.append(key, .object(JSONObject(map.keys.sorted(by: JSONObject.byteOrder).map { .init($0, .string(map[$0]!)) })))
        }
        object.append("profiles", .array(profiles.map(\.json)))
        object.members += extra.members
        return .object(object)
    }

    /// What the app sends to the dongle and hashes.
    public var minifiedData: Data { Data(json.minified.utf8) }
    /// What the app exports.
    public var prettyData: Data { Data(json.pretty.utf8) }
    public var sha8: String { ProfileFormat.sha8(minifiedData) }
    public var size: Int { minifiedData.count }

    /// The dongle's verdict: nil when it would save this set.
    public func validate() -> ProfileError? {
        do {
            _ = try ProfileFormat.check(json)
            return nil
        } catch {
            return error as? ProfileError ?? ProfileError("", error.localizedDescription)
        }
    }

    public func parsed() throws -> ParsedProfileSet { try ProfileFormat.check(json) }

    // MARK: lookups

    public func profile(id: String) -> GestureProfile? { profiles.first { $0.id == id } }

    public var ids: [String] { profiles.map(\.id) }

    /// The same content (what the dongle would see), ignoring the app's own identities.
    public func sameContent(as other: GestureProfileSet) -> Bool { minifiedData == other.minifiedData }

    /// A fresh id like `custom`, `custom-2`, … not used yet.
    public func unusedID(_ base: String = "custom") -> String {
        let base = String(ProfileFormat.asciiLowercased(base).filter { $0.isLetter && $0.isASCII || $0.isNumber && $0.isASCII || $0 == "-" }.prefix(12))
        let stem = base.isEmpty ? "custom" : base
        if !ids.contains(stem) { return stem }
        for n in 2... where !ids.contains("\(stem)-\(n)") { return "\(stem)-\(n)" }
        return stem
    }
}

public struct GestureProfile: Equatable, Sendable {
    /// The app's handle for lists; not in the file.
    public let uid: UUID
    public var id: String
    public var name: String
    /// 1–4; nil: not written (the dongle's default, 1).
    public var buzzName: String? = nil
    public var buzz: Int?
    /// Empty: everyone.
    public var hosts: [String]
    public var typing: Bool
    public var pointer: Bool
    /// Gesture name → binding. Unknown gesture names are kept (and reported by `validate()`).
    public var gestures: [String: GestureBinding]
    /// Mac bundle ids that switch a computer to this profile while they're in front.
    public var apps: [String] = []
    /// The app's own fields; the dongle ignores them.
    public var description: String?
    /// An SF Symbol name.
    public var symbol: String?
    /// A colour, `#rrggbb`.
    public var color: String?
    public var extra: JSONObject

    public init(id: String, name: String, buzz: Int? = nil, hosts: [String] = [], typing: Bool = false, pointer: Bool = false,
                gestures: [String: GestureBinding] = [:], description: String? = nil, symbol: String? = nil, color: String? = nil, extra: JSONObject = JSONObject()) {
        uid = UUID()
        self.id = id
        self.name = name
        self.buzz = buzz
        self.hosts = hosts
        self.typing = typing
        self.pointer = pointer
        self.gestures = gestures
        self.description = description
        self.symbol = symbol
        self.color = color
        self.extra = extra
    }

    public static func == (a: GestureProfile, b: GestureProfile) -> Bool {
        a.id == b.id && a.name == b.name && a.buzzName == b.buzzName && a.buzz == b.buzz && a.hosts == b.hosts && a.typing == b.typing && a.pointer == b.pointer
            && a.gestures == b.gestures && a.apps == b.apps && a.description == b.description && a.symbol == b.symbol && a.color == b.color && a.extra == b.extra
    }

    /// The same profile under a new identity (for "Duplicate"), without its apps (an app belongs to one profile).
    public func copy(id: String, name: String) -> GestureProfile {
        var copy = GestureProfile(id: id, name: name, buzz: buzz, hosts: hosts, typing: typing, pointer: pointer, gestures: gestures,
                       description: description, symbol: symbol, color: color, extra: extra)
        copy.buzzName = buzzName
        return copy
    }

    init(json: JSONValue, path: String) throws {
        guard let object = json.object else { throw ProfileError(path, "a profile is an object") }
        self.init(id: "", name: "")
        for member in object.members {
            let value = member.value
            let at = "\(path).\(member.key)"
            switch member.key {
            case "id": id = try GestureProfileSet.string(value, at)
            case "name": name = try GestureProfileSet.string(value, at)
            case "buzz" where value.string != nil: buzzName = value.string
            case "buzz" where value == .null: break
            case "buzz":
                guard let count = value.integer, let small = Int(exactly: count) else { throw ProfileError(at, "1–4 buzzes") }
                buzz = small
            case "hosts":
                guard let list = value.array else { throw ProfileError(at, "a list of host kinds") }
                hosts = try list.enumerated().map { try GestureProfileSet.string($1, "\(at)[\($0)]") }
            case "typing":
                guard let flag = value.bool else { throw ProfileError(at, "true or false") }
                typing = flag
            case "pointer":
                guard let flag = value.bool else { throw ProfileError(at, "true or false") }
                pointer = flag
            case "gestures":
                guard let map = value.object else { throw ProfileError(at, "an object of gesture → action") }
                gestures = [:]
                for gesture in map.members {
                    gestures[gesture.key] = try GestureBinding(json: gesture.value, path: "\(at).\(gesture.key)")
                }
            case "apps":
                guard let list = value.array else { throw ProfileError(at, "a list of app ids") }
                apps = try list.enumerated().map { try GestureProfileSet.string($1, "\(at)[\($0)]") }
            case "description": description = try GestureProfileSet.string(value, at)
            case "symbol": symbol = try GestureProfileSet.string(value, at)
            case "color": color = try GestureProfileSet.string(value, at)
            default: extra.append(member.key, value)
            }
        }
    }

    public var json: JSONValue {
        var object = JSONObject()
        object.append("id", .string(id))
        object.append("name", .string(name))
        if let symbol { object.append("symbol", .string(symbol)) }
        if let color { object.append("color", .string(color)) }
        if let description { object.append("description", .string(description)) }
        if !hosts.isEmpty { object.append("hosts", .array(hosts.map(JSONValue.string))) }
        if let buzzName { object.append("buzz", .string(buzzName)) } else if let buzz { object.append("buzz", .integer(Int64(buzz))) }
        if typing { object.append("typing", .bool(true)) }
        if pointer { object.append("pointer", .bool(true)) }
        if !apps.isEmpty { object.append("apps", .array(apps.map(JSONValue.string))) }
        if !gestures.isEmpty {
            let known = ProfileGesture.allCases.map(\.rawValue).filter { gestures[$0] != nil }
            let unknown = gestures.keys.filter { ProfileGesture(rawValue: $0) == nil }.sorted(by: JSONObject.byteOrder)
            object.append("gestures", .object(JSONObject((known + unknown).map { .init($0, gestures[$0]!.json) })))
        }
        object.members += extra.members
        return .object(object)
    }

    public subscript(gesture: ProfileGesture) -> GestureBinding? {
        get { gestures[gesture.rawValue] }
        set { gestures[gesture.rawValue] = newValue }
    }

    /// Who may use it, read (unknown names are skipped).
    public var hostKinds: [ProfileHosts] { hosts.compactMap(ProfileHosts.init(rawValue:)) }

    public func allows(_ type: DongleCommand.HostType) -> Bool { hostKinds.isEmpty || hostKinds.contains { $0.matches(type) } }
}

/// What one gesture does: one action for every host, or actions by kind of host (plus `default`).
public enum GestureBinding: Equatable, Sendable {
    case action(String)
    case byHost([String: String])

    public static let hostKeys = ProfileHosts.allCases.map(\.rawValue) + ["default"]

    init(json: JSONValue, path: String) throws {
        switch json {
        case .string(let text): self = .action(text)
        case .object: self = .byHost(try GestureProfileSet.strings(json, path))
        default: throw ProfileError(path, "an action string, or an object of them by host kind")
        }
    }

    public var json: JSONValue {
        switch self {
        case .action(let text):
            return .string(text)
        case .byHost(let map):
            let keys = Self.hostKeys.filter { map[$0] != nil } + map.keys.filter { !Self.hostKeys.contains($0) }.sorted(by: JSONObject.byteOrder)
            return .object(JSONObject(keys.map { .init($0, .string(map[$0]!)) }))
        }
    }

    public var buzz: String? {
        get { if case .byHost(let map) = self { return map["buzz"] }; return nil }
        set {
            var map: [String: String]
            switch self { case .action(let text): map = ["default": text]; case .byHost(let existing): map = existing }
            map["buzz"] = newValue
            self = .byHost(map)
        }
    }

    /// The action for every host (`default` of a by-host binding).
    public var defaultAction: String? {
        switch self {
        case .action(let text): text
        case .byHost(let map): map["default"]
        }
    }

    /// What a host of this type gets: the most specific matching kind (`mac` beats `computer`),
    /// then `default`.
    public func action(for type: DongleCommand.HostType) -> String? {
        switch self {
        case .action(let text):
            return text
        case .byHost(let map):
            let matching = ProfileHosts.allCases.filter { map[$0.rawValue] != nil && $0.matches(type) }
            return (matching.first(where: \.isSpecific) ?? matching.first).flatMap { map[$0.rawValue] } ?? map["default"]
        }
    }

    /// Host kind → action, without `default`.
    public var overrides: [String: String] {
        switch self {
        case .action: [:]
        case .byHost(let map): map.filter { $0.key != "default" && $0.key != "buzz" }
        }
    }

    /// Builds the simplest binding for a default and overrides (nil: unbound).
    public static func make(default action: String?, overrides: [String: String]) -> GestureBinding? {
        if overrides.isEmpty { return action.map(GestureBinding.action) }
        var map = overrides
        if let action { map["default"] = action }
        return .byHost(map)
    }
}

// MARK: sending a set

/// `profiles begin <bytes> <sha8>`, `profiles data <offset> <base64>` …, `profiles commit`
/// (PROFILES.md, "Sending a file to the dongle"). Chunks are small enough that every command
/// fits one write.
public struct ProfileUpload: Equatable, Sendable {
    /// Raw bytes per `profiles data` (200 base64 characters).
    public static let chunkSize = 150
    /// The longest command the dongle reads.
    public static let maxCommandBytes = 240

    public let data: Data
    public let sha8: String

    public init(_ data: Data) throws {
        guard !data.isEmpty, data.count <= ProfileFormat.maxBytes else {
            throw ProfileError("", "\(data.count) bytes is too big (at most \(ProfileFormat.maxBytes), minified)")
        }
        self.data = data
        sha8 = ProfileFormat.sha8(data)
    }

    public var commands: [DongleCommand] {
        var commands: [DongleCommand] = [.profilesBegin(bytes: data.count, sha8: sha8)]
        var offset = 0
        while offset < data.count {
            let end = min(offset + Self.chunkSize, data.count)
            commands.append(.profilesData(offset: offset, data.subdata(in: (data.startIndex + offset)..<(data.startIndex + end))))
            offset = end
        }
        commands.append(.profilesCommit)
        return commands
    }
}

// MARK: reading the dongle's set

/// `profiles show` read back from the dongle's log (0.12.1 on): `PROFILES: show begin <bytes>
/// <sha8> [builtin]`, `PROFILES: show data <offset> <base64>`…, `PROFILES: show end`.
public struct ProfileDump: Sendable {
    public struct File: Equatable, Sendable {
        public let data: Data
        public let sha8: String
        /// The dongle has no set of its own: this is its built-in one.
        public let builtin: Bool
    }

    /// Set once `end` arrives: the file, or why it doesn't add up.
    public private(set) var result: Result<File, ProfileError>?
    private var begun: (length: Int, sha8: String, builtin: Bool)?
    private var chunks: [Int: Data] = [:]

    public init() {}

    public mutating func feed(_ line: String) {
        guard result == nil, let marker = line.range(of: "PROFILES: show ") else { return }
        let words = line[marker.upperBound...].split(separator: " ").map(String.init)
        switch words.first {
        case "begin" where words.count >= 3:
            guard let length = Int(words[1]) else { return }
            begun = (length, words[2], words.dropFirst(3).contains("builtin"))
            chunks = [:]
        case "data" where words.count == 3 && begun != nil:
            guard let offset = Int(words[1]), let bytes = Data(base64Encoded: words[2]) else { return }
            chunks[offset] = bytes
        case "end" where begun != nil:
            let begun = begun!
            let data = chunks.keys.sorted().reduce(into: Data()) { $0.append(chunks[$1]!) }
            if data.count == begun.length && ProfileFormat.sha8(data) == begun.sha8 {
                result = .success(File(data: data, sha8: begun.sha8, builtin: begun.builtin))
            } else {
                result = .failure(ProfileError("", "Some of the dongle's set went missing on the way (\(data.count) of \(begun.length) bytes). Try again."))
            }
        default:
            break
        }
    }
}

// MARK: pasted text

extension ProfileFormat {
    /// The JSON in pasted text: an AI assistant's answer usually wraps it in a ``` block or a
    /// sentence. Takes the first fenced block if there is one, then the outermost `{ … }`.
    public static func extractJSON(from text: String) -> String {
        var body = text
        if let fence = body.range(of: "```") {
            let afterFence = body[fence.upperBound...]
            let contentStart = afterFence.firstIndex(of: "\n").map { afterFence.index(after: $0) } ?? afterFence.startIndex
            if let close = body.range(of: "```", range: contentStart..<body.endIndex) {
                body = String(body[contentStart..<close.lowerBound])
            }
        }
        guard let open = body.firstIndex(of: "{"), let close = body.lastIndex(of: "}"), open < close else {
            return body.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return String(body[open...close])
    }
}
