import DongleProtocol
import SwiftUI

/// The profile vocabulary at a glance: the names to use when writing a file by hand (or asking an
/// AI assistant to), as PROFILES.md has them.
struct ReferenceView: View {
    @State private var copied = false

    var body: some View {
        List {
            Section {
                Text("A profile set is a JSON file: `format` \"np-profiles\", `version` 1, an optional `name`, `menu`, `start` and `everywhere`, and 1–12 `profiles`. Each profile has an `id`, a `name`, and `gestures`: gesture name → action. `everywhere` has gestures too: they work in every profile and win over its own.")
                    .font(.callout)
                Button {
                    Clipboard.copy(ProfileFormat.assistantBrief)
                    copied = true
                } label: {
                    Label(copied ? "Copied" : "Copy the rules for an AI assistant", systemImage: copied ? "checkmark" : "sparkles")
                }
            }
            ForEach(ProfileGesture.Group.allCases, id: \.self) { group in
                Section(group.rawValue) {
                    ForEach(ProfileGesture.allCases.filter { $0.group == group }, id: \.self) { gesture in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Image(systemName: gesture.symbol).foregroundStyle(gesture.tint).frame(width: 22)
                                Text(gesture.rawValue).font(.callout.monospaced().weight(.semibold)).textSelection(.enabled)
                            }
                            Text(gesture.detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section {
                ForEach(ProfileFormat.actionReference, id: \.action) { entry in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.action).font(.callout.monospaced().weight(.semibold)).textSelection(.enabled)
                        Text(entry.meaning).font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Actions")
            } footer: {
                Text("A gesture can also map to an object by kind of host: {\"phone\": …, \"computer\": …, \"mac\": …, \"windows\": …, \"linux\": …, \"tv\": …, \"default\": …}. The most specific kind wins, then default.")
            }
            Section {
                ReferenceLine(title: "Modifiers", text: "cmd (command, win, super) · ctrl · alt (option) · shift, joined with +")
                ReferenceLine(title: "Letters and digits", text: "a–z (a capital adds Shift), 0–9")
                ReferenceLine(title: "Named keys", text: ProfileFormat.namedKeys.joined(separator: " "))
                ReferenceLine(title: "Symbols", text: ProfileFormat.symbolKeys)
                ReferenceLine(title: "Examples", text: "key:enter  key:cmd+shift+m  key:ctrl+alt+delete  key:f5  key:]  key:cmd++  hold:alt+space")
            } header: {
                Text("Keys")
            } footer: {
                Text("Windows and Linux get cmd as Ctrl, so key:cmd+c copies everywhere.")
            }
            Section("Host kinds") {
                ForEach(ProfileHosts.allCases, id: \.self) { hosts in
                    HStack {
                        Label(hosts.title, systemImage: hosts.symbol)
                        Spacer()
                        Text(hosts.rawValue).font(.callout.monospaced()).foregroundStyle(.secondary)
                    }
                }
            }
            Section("Buzzes and Gesture lab") {
                Text("Design patterns in Buzzes. Pulse widths show duration, heights show strength. Play previews a draft without sending the set. Built-ins can be customized for every place they are used.")
                Text("Feedback chooses a pattern or None for each moment. A binding may choose its own buzz. A profile switch can play 1–4 taps or a named pattern.")
                Text("In Gesture lab, try movements to discover the band’s raw events. Bind an event in any profile, or inspect raw fields and flick peaks. Lab logging stops when you leave. Flicks, band events and buzz patterns need firmware 0.15.0.")
                Text("Patterns: 20–2000 ms pulses, 20–3000 ms pauses, strength 1–100. Up to 16 steps, 8 seconds and 120 bytes; start and end with a pulse. Example: 250 _200 250*90.")
            }
            Section("Limits") {
                ReferenceLine(title: "Profiles", text: "1–\(ProfileFormat.maxProfiles); ids 1–16 of a–z, 0–9, -, not \(ProfileFormat.reservedIDs.joined(separator: ", ")); names 1–24 characters; buzz 1–4 or a pattern name")
                ReferenceLine(title: "Menu", text: "one letter a–z or digit 0–9 → any action but hold:, mouse:point and menu")
                ReferenceLine(title: "Modes", text: "home is a host's start profile. profile:<id>, profile:app and the menu go up (two levels remembered); profile:back goes down one, home at the bottom (home's buzz again); profile:next and previous move sideways")
                ReferenceLine(title: "Size", text: "at most \(ProfileFormat.maxBytes) bytes minified, the app's own fields (description, symbol, color) included")
            }
        }
        .darkList()
        .navigationTitle("Reference")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct ReferenceLine: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(text).font(.callout.monospaced()).textSelection(.enabled)
        }
    }
}
