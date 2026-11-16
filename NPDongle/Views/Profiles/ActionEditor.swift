import DongleProtocol
import SwiftUI

/// Where an action is used, which decides what it may be.
struct ActionContext {
    /// Profile ids in the set, for `profile:<id>`.
    var ids: [String]
    /// `hold:` (middle.hold only).
    var allowsHold: Bool
    /// `mouse:point` (middle.hold only).
    var allowsPoint: Bool
    /// `menu` (not inside the menu itself).
    var allowsMenu = true
    /// "Not set" (a gesture may be unbound; a menu letter or an override always has an action).
    var allowsUnset = true
    /// The validator's path, for messages.
    var path: String
}

/// The kinds of action the editor offers, read from and written to the action string.
enum ActionKind: String, CaseIterable, Identifiable {
    case unset, none, media, phoneMute, call, mouse, profile, host, menu, write, key, hold, type, buzz, apps, custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .unset: "Not set"
        case .none: "Nothing"
        case .media: "Media key"
        case .phoneMute: "Phone mute"
        case .call: "Phone call"
        case .mouse: "Mouse"
        case .profile: "Switch profile"
        case .host: "Switch host"
        case .menu: "Letter menu"
        case .write: "Handwriting"
        case .key: "Key…"
        case .hold: "Hold key…"
        case .type: "Type text…"
        case .buzz: "Play buzz"
        case .apps: "Switch app"
        case .custom: "Written by hand…"
        }
    }

    var symbol: String {
        switch self {
        case .unset: "circle.dashed"
        case .none: "nosign"
        case .media: "playpause"
        case .phoneMute: "mic.slash"
        case .call: "phone"
        case .mouse: "computermouse"
        case .profile: "rectangle.stack"
        case .host: "arrow.left.arrow.right"
        case .menu: "character.cursor.ibeam"
        case .write: "pencil.and.scribble"
        case .key: "keyboard"
        case .hold: "keyboard.badge.ellipsis"
        case .type: "text.cursor"
        case .buzz: "waveform"
        case .apps: "rectangle.on.rectangle"
        case .custom: "chevron.left.forwardslash.chevron.right"
        }
    }

    init(_ action: String?) {
        guard let action else { self = .unset; return }
        let kind = action.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? action
        switch kind {
        case "none" where action == "none": self = .none
        case "menu" where action == "menu": self = .menu
        case "write": self = .write
        case "phoneMute" where action == "phoneMute": self = .phoneMute
        case "call" where CallAction(rawValue: String(action.dropFirst(5))) != nil: self = .call
        case "media" where MediaKey(rawValue: String(action.dropFirst(6))) != nil: self = .media
        case "mouse": self = .mouse
        case "profile": self = .profile
        case "host": self = .host
        case "key": self = .key
        case "hold": self = .hold
        case "type": self = .type
        case "buzz": self = .buzz
        case "apps": self = .apps
        default: self = .custom
        }
    }

    /// A sensible first action when the user picks this kind.
    func starter(ids: [String], current: String?) -> String? {
        switch self {
        case .unset: nil
        case .none: "none"
        case .media: "media:playPause"
        case .phoneMute: "phoneMute"
        case .call: "call:answer"
        case .mouse: "mouse:click"
        case .profile: "profile:\(ids.first ?? "next")"
        case .host: "host:next"
        case .menu: "menu"
        case .write: "write"
        case .key: "key:enter"
        case .hold: "hold:alt+space"
        case .type: "type:Hello"
        case .buzz: "buzz:tick"
        case .apps: "apps:next"
        case .custom: current ?? "none"
        }
    }

    /// One-line description of an action string, for lists.
    static func summary(_ action: String?, profileName: (String) -> String) -> String {
        guard let action else { return "Not set" }
        let arg = action.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).dropFirst().first.map(String.init) ?? ""
        switch ActionKind(action) {
        case .unset: return "Not set"
        case .none: return "Nothing"
        case .media: return MediaKey(rawValue: arg)?.title ?? action
        case .phoneMute: return "Phone mute"
        case .call: return CallAction(rawValue: arg)?.title ?? action
        case .menu: return "Letter menu"
        case .write: return "Handwriting (\(arg.isEmpty ? "\(ProfileFormat.writeSeconds)" : arg) s)"
        case .profile:
            return ProfileTarget.words.first { $0.word == arg }?.title ?? "Profile: \(profileName(arg))"
        case .host:
            switch arg {
            case "next": return "Next host"
            case "previous": return "Previous host"
            default: return "Host: \(ProfileHosts(rawValue: arg)?.title ?? arg)"
            }
        case .key: return "Key \(arg)"
        case .hold: return "Hold \(arg)"
        case .type: return "Type “\(arg)”"
        case .buzz: return "Buzz: \(arg)"
        case .apps: return arg == "previous" ? "Previous app" : "Next app"
        case .mouse where arg == "point": return ProfileAction.pointTitle
        case .mouse, .custom: return action
        }
    }
}

/// Edits one action string: pick a kind, then its details, with the dongle's verdict underneath.
struct ActionEditor: View {
    @Environment(DongleModel.self) private var model
    @Binding var action: String?
    let context: ActionContext

    private var kinds: [ActionKind] {
        ActionKind.allCases.filter { kind in
            switch kind {
            case .unset: context.allowsUnset
            case .hold: context.allowsHold || ActionKind(action) == .hold
            case .menu: context.allowsMenu || ActionKind(action) == .menu
            default: true
            }
        }
    }

    private var kind: Binding<ActionKind> {
        Binding(get: { ActionKind(action) }, set: { action = $0.starter(ids: context.ids, current: action) })
    }

    /// The text after the first colon.
    private var argument: Binding<String> {
        Binding(get: {
            guard let action, let colon = action.firstIndex(of: ":") else { return "" }
            return String(action[action.index(after: colon)...])
        }, set: { value in
            let prefix = action.flatMap { text in text.firstIndex(of: ":").map { String(text[..<$0]) } } ?? ActionKind(action).rawValue
            action = "\(prefix):\(value)"
        })
    }

    var body: some View {
        Picker(selection: kind) {
            ForEach(kinds) { kind in Label(kind.title, systemImage: kind.symbol).tag(kind) }
        } label: {
            Text("Action")
        }
        .pickerStyle(.menu)
        details
        if let action {
            VerdictRow(action: action, context: context)
        }
    }

    @ViewBuilder
    private var details: some View {
        switch ActionKind(action) {
        case .media:
            Picker("Key", selection: argument) {
                ForEach(MediaKey.allCases, id: \.self) { key in Text(key.title).tag(key.rawValue) }
            }
        case .call:
            Picker("Call", selection: argument) {
                ForEach(CallAction.allCases, id: \.self) { call in Text(call.title).tag(call.rawValue) }
            }
            Text("On an iPhone that shares its notifications with the dongle (it asks once), whichever host is active. A ringing call buzzes the band; with no call, a long buzz.")
                .font(.caption).foregroundStyle(.secondary)
        case .buzz:
            Picker("Pattern", selection: argument) {
                ForEach(model.store.set.buzzNames, id: \.self) { Text($0).tag($0) }
            }
        case .apps:
            Picker("Direction", selection: argument) {
                Text("Next app").tag("next")
                Text("Previous app").tag("previous")
            }
            Text("Computers only. Best on flicks: keep pinching to browse apps, then release to choose. Requires firmware 0.15.0.").font(.caption).foregroundStyle(.secondary)
        case .mouse:
            MouseEditor(argument: argument, allowsPoint: context.allowsPoint)
        case .profile:
            let word = argument.wrappedValue
            Picker("Profile", selection: argument) {
                ForEach(ProfileTarget.words, id: \.word) { target in Text(target.title).tag(target.word) }
                ForEach(context.ids, id: \.self) { id in Text(id).tag(id) }
                if !ProfileFormat.reservedIDs.contains(word), !context.ids.contains(word) {
                    Text("\(word) (missing)").tag(word)
                }
            }
            if let detail = ProfileTarget.detail(word) {
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        case .host:
            Picker("Host", selection: argument) {
                Text("Next host").tag("next")
                Text("Previous host").tag("previous")
                ForEach(ProfileHosts.allCases, id: \.self) { hosts in Text("First \(hosts.title.lowercased())").tag(hosts.rawValue) }
                if !["next", "previous"].contains(argument.wrappedValue), ProfileHosts(rawValue: argument.wrappedValue) == nil {
                    Text(argument.wrappedValue).tag(argument.wrappedValue)
                }
            }
        case .key, .hold:
            ChordEditor(chord: argument)
        case .type:
            TextField("Text to type", text: argument)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Text("\(argument.wrappedValue.utf8.count) of 64 characters, printable ASCII (US layout).").font(.caption).foregroundStyle(.secondary)
        case .custom:
            TextField("Action, like media:mute", text: Binding(get: { action ?? "" }, set: { action = $0 }))
                .font(.body.monospaced())
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        case .write:
            let seconds = Int(argument.wrappedValue) ?? ProfileFormat.writeSeconds
            Stepper("Off after \(seconds) s with nothing written", value: Binding(get: { seconds }, set: { action = $0 == ProfileFormat.writeSeconds ? "write" : "write:\($0)" }), in: 3...60)
            Text("Two buzzes: write on any surface, and letters are typed on the computer. Each letter restarts the timer; one buzz when it turns off. Doing it again while it's on turns it off.")
                .font(.caption).foregroundStyle(.secondary)
        case .unset, .none, .phoneMute, .menu:
            EmptyView()
        }
    }
}

/// The action as the file says it, and what the dongle makes of it.
struct VerdictRow: View {
    let action: String
    let context: ActionContext
    @Environment(DongleModel.self) private var model

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(action).font(.caption.monospaced()).textSelection(.enabled)
            Spacer()
            if problem != nil {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.danger)
            } else {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.mint)
            }
        }
        if let problem { Text(problem).font(.caption).foregroundStyle(Theme.danger) }
    }

    private var problem: String? {
        do {
            let parsed = try ProfileFormat.parseAction(action, ids: context.ids, path: context.path, buzzes: model.store.set.buzzes.compactMapValues { try? ProfileFormat.parsePattern($0) })
            switch parsed {
            case .hold where !context.allowsHold && context.allowsMenu:
                return "hold: only works on middle.hold (it's released with the finger)"
            case .point where !context.allowsPoint && context.allowsMenu:
                return "mouse:point only works on middle.hold (the pointer moves while it's held)"
            case .hold where !context.allowsMenu, .point where !context.allowsMenu, .menu where !context.allowsMenu:
                return "The menu can't hold a key, point or open itself."
            default:
                return nil
            }
        } catch let error as ProfileError {
            return error.message
        } catch {
            return error.localizedDescription
        }
    }
}

struct MouseEditor: View {
    @Binding var argument: String
    /// `mouse:point` is offered (middle.hold only).
    var allowsPoint = false
    private static let known = ["click", "rightClick", "middleClick", "scrollUp", "scrollDown", "point"] + (4...8).map { "button\($0)" }

    private var parts: (what: String, steps: Int?) {
        let split = argument.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        return (split.first.map(String.init) ?? "click", split.count > 1 ? Int(split[1]) : nil)
    }

    var body: some View {
        let parts = parts
        Picker("Mouse", selection: Binding(get: { parts.what }, set: { argument = $0 })) {
            Text("Click").tag("click")
            Text("Right click").tag("rightClick")
            Text("Middle click").tag("middleClick")
            ForEach(4...8, id: \.self) { n in Text("Button \(n)").tag("button\(n)") }
            Text("Scroll up").tag("scrollUp")
            Text("Scroll down").tag("scrollDown")
            if allowsPoint || parts.what == "point" { Text(ProfileAction.pointTitle).tag("point") }
            if !Self.known.contains(parts.what) { Text(parts.what).tag(parts.what) }
        }
        if parts.what == "point" {
            Text("The wrist moves the pointer while the finger is held (turn the forearm), and stops when it lets go; index taps in the next 3 s click where it stopped. Computers, and an iPhone with AssistiveTouch on. Firmware 0.17.")
                .font(.caption).foregroundStyle(.secondary)
        }
        if parts.what.hasPrefix("button") {
            Text("On an iPhone, give it an action in Settings › Accessibility › Touch › AssistiveTouch › Devices: press the gesture when it asks for the button. On a computer, 4 is back and 5 forward.")
                .font(.caption).foregroundStyle(.secondary)
        }
        if parts.what.hasPrefix("scroll") {
            Stepper("\(parts.steps ?? 4) wheel steps", value: Binding(get: { parts.steps ?? 4 }, set: { argument = $0 == 4 ? parts.what : "\(parts.what):\($0)" }), in: 1...20)
        }
    }
}

/// A chord (`cmd+shift+m`) with modifier toggles, quick keys and the dongle's verdict.
struct ChordEditor: View {
    @Binding var chord: String

    private static let quickKeys = ["enter", "escape", "space", "tab", "backspace", "left", "right", "up", "down", "f5"]
    private static let modifiers: [(name: String, symbol: String)] = [("cmd", "⌘"), ("ctrl", "⌃"), ("alt", "⌥"), ("shift", "⇧")]

    /// Modifier names and the key, split the way the dongle reads them.
    private var parts: (modifiers: [String], key: String) {
        if chord.hasSuffix("++") { return (chord.dropLast(2).split(separator: "+").map(String.init), "+") }
        guard let plus = chord.lastIndex(of: "+"), chord.index(after: plus) < chord.endIndex else { return ([], chord) }
        return (chord[..<plus].split(separator: "+").map { $0.lowercased() }, String(chord[chord.index(after: plus)...]))
    }

    private func set(modifiers: [String], key: String) {
        let ordered = Self.modifiers.map(\.name).filter { modifiers.contains($0) } + modifiers.filter { name in !Self.modifiers.contains { $0.name == name } }
        chord = (ordered + [key]).joined(separator: "+")
    }

    var body: some View {
        let parts = parts
        TextField("Chord, like cmd+shift+m", text: $chord)
            .font(.body.monospaced())
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        HStack {
            ForEach(Self.modifiers, id: \.name) { modifier in
                let on = parts.modifiers.contains(modifier.name)
                Button {
                    set(modifiers: on ? parts.modifiers.filter { $0 != modifier.name } : parts.modifiers + [modifier.name], key: parts.key)
                } label: {
                    Text(modifier.symbol).font(.title3).frame(maxWidth: .infinity, minHeight: 32)
                }
                .buttonStyle(.bordered)
                .tint(on ? Theme.accent : .gray)
                .accessibilityLabel("\(modifier.name) \(on ? "on" : "off")")
            }
        }
        ScrollView(.horizontal, showsIndicators: false) {
            HStack {
                ForEach(Self.quickKeys, id: \.self) { key in
                    Button(key) { set(modifiers: parts.modifiers, key: key) }
                        .buttonStyle(.bordered)
                        .font(.caption.monospaced())
                }
            }
        }
        if case .failure(let error) = ProfileFormat.parseChord(chord) {
            Text(error.message).font(.caption).foregroundStyle(Theme.danger)
        }
    }
}
