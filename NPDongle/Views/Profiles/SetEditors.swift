import DongleProtocol
import SwiftUI

/// The letter menu: pinch, hold and let go (two buzzes), then write one letter.
struct MenuEditorView: View {
    @Environment(DongleModel.self) private var model

    private var store: ProfileStore { model.store }
    private static let letters = (Array("abcdefghijklmnopqrstuvwxyz") + Array("0123456789")).map(String.init)

    var body: some View {
        let menu = store.set.menu
        let keys = menu.keys.sorted()
        List {
            Section {
                ForEach(keys, id: \.self) { letter in
                    NavigationLink {
                        MenuLetterEditor(letter: letter)
                    } label: {
                        HStack(spacing: 14) {
                            Text(letter.uppercased())
                                .font(.title3.monospaced().weight(.bold))
                                .frame(width: 34, height: 34)
                                .background(Theme.accent.opacity(0.16), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            Text(ActionKind.summary(menu[letter], profileName: { store.set.profile(id: $0)?.name ?? $0 }))
                            Spacer()
                            if problem(letter) { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.danger) }
                        }
                    }
                }
                .onDelete { offsets in
                    for offset in offsets { store.set.menu[keys[offset]] = nil }
                }
                let free = Self.letters.filter { menu[$0] == nil }
                if !free.isEmpty {
                    Menu {
                        ForEach(free, id: \.self) { letter in
                            Button(letter) { store.set.menu[letter] = "profile:\(store.set.ids.first ?? "next")" }
                        }
                    } label: {
                        Label("Add a letter", systemImage: "plus.circle")
                    }
                }
            } footer: {
                Text("Pinch, hold a moment and let go without turning (two buzzes), then write one letter on any surface within 6 s. A letter that isn't here gets one long buzz. The band often reads l, 1, i and | as each other: the menu treats them as l.")
            }
        }
        .darkList()
        .navigationTitle("Letter menu")
        .toolbar { EditButton() }
    }

    private func problem(_ letter: String) -> Bool { store.validation?.path == "menu.\(letter)" }
}

struct MenuLetterEditor: View {
    @Environment(DongleModel.self) private var model
    let letter: String

    private var store: ProfileStore { model.store }

    var body: some View {
        Form {
            Section {
                ActionEditor(action: Binding(get: { store.set.menu[letter] }, set: { store.set.menu[letter] = $0 ?? "none" }),
                             context: ActionContext(ids: store.set.ids, allowsHold: false, allowsMenu: false, allowsUnset: false, path: "menu.\(letter)"))
            } footer: {
                Text("Anything but a held key or the menu itself. Switching profile buzzes that profile's count; switching host buzzes once for a phone, twice for a computer.")
            }
            Section {
                Button("Remove \(letter.uppercased()) from the menu", role: .destructive) { store.set.menu[letter] = nil }
            }
        }
        .scrollContentBackground(.hidden)
        .screenBackground()
        .navigationTitle("Letter \(letter.uppercased())")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The profile each kind of host starts in.
struct StartProfilesView: View {
    @Environment(DongleModel.self) private var model

    private var store: ProfileStore { model.store }

    var body: some View {
        Form {
            row("phone", title: "Phones", symbol: "iphone", types: [.phone])
            row("computer", title: "Computers", symbol: "laptopcomputer", types: [.mac, .windows, .linux])
            row("tv", title: "TVs", symbol: "tv", types: [.tv])
            Section {} footer: {
                Text("A new host starts in this profile; after that each host remembers what you last chose for it. Automatic: the first profile that allows that kind of host. A computer's start profile must allow Mac, Windows and Linux.")
            }
        }
        .scrollContentBackground(.hidden)
        .screenBackground()
        .navigationTitle("Start profiles")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ group: String, title: String, symbol: String, types: [DongleCommand.HostType]) -> some View {
        let allowed = store.set.profiles.filter { profile in types.allSatisfy { profile.allows($0) } }
        let current = store.set.start[group] ?? ""
        return Section {
            Picker(selection: Binding(get: { current }, set: { store.set.start[group] = $0.isEmpty ? nil : $0 })) {
                Text("Automatic (\(allowed.first?.name ?? "none"))").tag("")
                ForEach(allowed, id: \.uid) { profile in Label(profile.name, systemImage: profile.displaySymbol).tag(profile.id) }
                if !current.isEmpty, !allowed.contains(where: { $0.id == current }) {
                    Text("\(current) (not allowed)").tag(current)
                }
            } label: {
                Label(title, systemImage: symbol)
            }
            if store.validation?.path == "start.\(group)", let error = store.validation {
                ProblemText(error: error)
            }
        }
    }
}

/// A file or paste on its way in.
struct ImportReviewView: View {
    @Environment(DongleModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let candidate: ProfileStore.Candidate

    var body: some View {
        List {
            Section {
                InfoRow(label: "From", value: candidate.source)
                if let set = candidate.set {
                    InfoRow(label: "Name", value: set.name ?? "—")
                    InfoRow(label: "Size", value: "\(set.size) of \(ProfileFormat.maxBytes) bytes")
                }
                if let error = candidate.error {
                    Label(candidate.set == nil ? "This isn't a profile set the app can read" : "The dongle would refuse this set",
                          systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.danger)
                    ProblemText(error: error)
                } else {
                    Label("Valid: the dongle would take it", systemImage: "checkmark.shield").foregroundStyle(Theme.mint)
                }
            }
            if let set = candidate.set {
                Section("Profiles") {
                    ForEach(set.profiles, id: \.uid) { profile in ProfileRow(profile: profile) }
                }
                Section {
                    Button {
                        model.store.apply(candidate)
                        dismiss()
                    } label: {
                        Label(candidate.error == nil ? "Replace this phone's set" : "Import anyway and fix it here", systemImage: "square.and.arrow.down")
                    }
                } footer: {
                    Text(candidate.dongleHash != nil
                         ? "This replaces the set on this phone with the dongle's (export it first to keep it). The dongle already has it: no need to send."
                         : "This replaces the set on this phone (export it first to keep it). The dongle changes only when you send.")
                }
            }
        }
        .darkList()
        .navigationTitle("Import profiles")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
    }
}
