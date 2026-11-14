import DongleProtocol
import SwiftUI

/// A profile, with its gesture bindings first and settings below.
struct ProfileEditorView: View {
    @Environment(DongleModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let uid: UUID
    @State private var draftID = ""
    @State private var confirmDelete = false

    private var store: ProfileStore { model.store }
    private var index: Int? { store.set.profiles.firstIndex { $0.uid == uid } }

    /// The profile, looked up by identity on every read and write (the list may change under it).
    private var profile: Binding<GestureProfile> {
        Binding(get: {
            store.set.profiles.first { $0.uid == uid } ?? GestureProfile(id: "", name: "")
        }, set: { value in
            if let index = store.set.profiles.firstIndex(where: { $0.uid == uid }) { store.set.profiles[index] = value }
        })
    }

    var body: some View {
        if let index {
            form(index)
                .onAppear { draftID = profile.wrappedValue.id }
        } else {
            ContentUnavailableView("Profile deleted", systemImage: "trash", description: Text("This profile isn't in the set any more."))
                .screenBackground()
        }
    }

    private func problem(_ index: Int) -> ProfileError? {
        guard let error = store.validation, error.path == "profiles[\(index)]" || error.path.hasPrefix("profiles[\(index)].") else { return nil }
        return error
    }

    private func form(_ index: Int) -> some View {
        let profile = profile
        return Form {
            if let error = problem(index) {
                Section {
                    Label("The dongle would refuse this", systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.danger)
                    ProblemText(error: error)
                }
            }
            ForEach(ProfileGesture.Group.allCases.filter { $0 != .band }, id: \.self) { group in
                Section(group.rawValue) {
                    ForEach(ProfileGesture.allCases.filter { $0.group == group }, id: \.self) { gesture in
                        NavigationLink {
                            BindingEditorView(uid: uid, gesture: gesture)
                        } label: {
                            GestureRow(gesture: gesture, binding: profile.wrappedValue[gesture],
                                       broken: problem(index)?.path.hasPrefix("profiles[\(index)].gestures.\(gesture.rawValue)") == true)
                        }
                    }
                }
            }
            Section {
                ForEach(ProfileGesture.band.filter { profile.wrappedValue[$0] != nil }, id: \.self) { gesture in
                    NavigationLink {
                        BindingEditorView(uid: uid, gesture: gesture)
                    } label: {
                        GestureRow(gesture: gesture, binding: profile.wrappedValue[gesture],
                                   broken: problem(index)?.path.hasPrefix("profiles[\(index)].gestures.\(gesture.rawValue)") == true)
                    }
                }
                NavigationLink { BandEventsView(uid: uid) } label: { Label("Bind a band event…", systemImage: "plus.circle") }
                FirmwareFeatureNote()
            } header: { Text("Band events (experimental)") }
            Section {
                TextField("Name", text: profile.name)
                if profile.wrappedValue.name.unicodeScalars.count > 24 {
                    Text("At most 24 characters.").font(.caption).foregroundStyle(Theme.danger)
                }
                HStack {
                    Text("ID").foregroundStyle(.secondary)
                    TextField("id", text: $draftID)
                        .font(.body.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .multilineTextAlignment(.trailing)
                        .onSubmit { commitID() }
                }
                if draftID != profile.wrappedValue.id {
                    idHint
                }
                TextField("Description (for you)", text: optional(profile.description), axis: .vertical)
                    .lineLimit(1...4)
            } header: {
                Text("Profile")
            } footer: {
                Text("The id is what menu letters and profile: actions use (1–16 of a–z, 0–9 and -). Renaming it updates them.")
            }
            Section("Look") {
                SymbolPicker(symbol: optional(profile.symbol), tint: profile.wrappedValue.tint)
                ColorSwatches(color: profile.color)
            }
            Section {
                Picker("Switch buzz", selection: Binding(get: { profile.wrappedValue.buzzName.map { "pattern:" + $0 } ?? "count:\(profile.wrappedValue.buzz ?? 1)" }, set: { value in
                    if value.hasPrefix("count:"), let count = Int(value.dropFirst(6)) { profile.wrappedValue.buzz = count; profile.wrappedValue.buzzName = nil }
                    else { profile.wrappedValue.buzzName = String(value.dropFirst(8)); profile.wrappedValue.buzz = nil }
                })) {
                    ForEach(1...4, id: \.self) { Text("\($0) buzzes").tag("count:\($0)") }
                    ForEach(store.set.buzzNames, id: \.self) { Text($0).tag("pattern:" + $0) }
                }
                Toggle(isOn: profile.typing) {
                    Label { Text("Type handwriting"); Text("Computers: what you write with a finger is typed").font(.caption) } icon: { Image(systemName: "pencil.and.scribble") }
                }
                Toggle(isOn: profile.pointer) {
                    Label { Text("Air mouse"); Text("Computers: pinch, hold and move the wrist").font(.caption) } icon: { Image(systemName: "computermouse") }
                }
            } header: {
                Text("Behaviour")
            }
            hostsSection(profile)
            AppsSection(apps: profile.apps, broken: problem(index)?.path.hasPrefix("profiles[\(index)].apps") == true)
            unknownGestures(profile)
            Section {
                Button("Delete profile", role: .destructive) { confirmDelete = true }
                    .disabled(store.set.profiles.count <= 1)
            }
        }
        .scrollContentBackground(.hidden)
        .screenBackground()
        .navigationTitle(profile.wrappedValue.name.isEmpty ? "Profile" : profile.wrappedValue.name)
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { commitID() }
        .confirmationDialog("Delete “\(profile.wrappedValue.name)”?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let index = self.index { store.delete(at: IndexSet(integer: index)) }
                dismiss()
            }
        } message: {
            Text("Menu letters, start entries and actions that switch to it are removed too.")
        }
    }

    @ViewBuilder
    private var idHint: some View {
        if !ProfileFormat.isValidID(draftID) {
            Text("1–16 of a–z, 0–9 and -").font(.caption).foregroundStyle(Theme.danger)
        } else if store.set.ids.contains(draftID) {
            Text("Another profile uses “\(draftID)”.").font(.caption).foregroundStyle(Theme.danger)
        } else {
            Button("Use “\(draftID)”") { commitID() }.font(.callout)
        }
    }

    private func commitID() {
        let old = profile.wrappedValue.id
        guard draftID != old else { return }
        guard ProfileFormat.isValidID(draftID), !store.set.ids.contains(draftID) else { return }
        store.rename(id: old, to: draftID)
    }

    private func hostsSection(_ profile: Binding<GestureProfile>) -> some View {
        Section {
            ForEach(ProfileHosts.allCases, id: \.self) { hosts in
                Toggle(isOn: Binding(get: { profile.wrappedValue.hosts.contains(hosts.rawValue) }, set: { on in
                    if on {
                        profile.wrappedValue.hosts.append(hosts.rawValue)
                    } else {
                        profile.wrappedValue.hosts.removeAll { $0 == hosts.rawValue }
                    }
                })) {
                    Label(hosts.title, systemImage: hosts.symbol)
                }
            }
            ForEach(profile.wrappedValue.hosts.filter { ProfileHosts(rawValue: $0) == nil }, id: \.self) { name in
                HStack {
                    Label("\(name) (unknown)", systemImage: "questionmark.circle").foregroundStyle(Theme.danger)
                    Spacer()
                    Button("Remove") { profile.wrappedValue.hosts.removeAll { $0 == name } }
                }
            }
        } header: {
            Text("Who may use it")
        } footer: {
            Text(profile.wrappedValue.hosts.isEmpty
                 ? "None picked: every host may use it. Switching a host to a profile it can't use gets one long buzz."
                 : "Only these may switch to it. “Any computer” covers Mac, Windows and Linux.")
        }
    }

    @ViewBuilder
    private func unknownGestures(_ profile: Binding<GestureProfile>) -> some View {
        let unknown = profile.wrappedValue.gestures.keys.filter { ProfileGesture(rawValue: $0) == nil }.sorted()
        if !unknown.isEmpty {
            Section {
                ForEach(unknown, id: \.self) { name in
                    HStack {
                        Text(name).font(.callout.monospaced()).foregroundStyle(Theme.danger)
                        Spacer()
                        Button("Remove") { profile.wrappedValue.gestures[name] = nil }
                    }
                }
            } header: {
                Text("Unknown gestures")
            } footer: {
                Text("The dongle doesn't know these names. See the reference for the gestures it knows.")
            }
        }
    }
}

/// Empty text ↔ nil, for the optional fields.
@MainActor
func optional(_ binding: Binding<String?>) -> Binding<String> {
    Binding(get: { binding.wrappedValue ?? "" }, set: { binding.wrappedValue = $0.isEmpty ? nil : $0 })
}

struct GestureRow: View {
    @Environment(DongleModel.self) private var model
    let gesture: ProfileGesture
    let binding: GestureBinding?
    var broken = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: gesture.symbol).foregroundStyle(gesture.tint).frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(gesture.title)
                    .font(gesture.group == .band ? .callout.monospaced() : .body)
                    .lineLimit(1).minimumScaleFactor(0.75)
                Text(summary).font(.caption).foregroundStyle(binding == nil ? .tertiary : .secondary).lineLimit(2)
            }
            Spacer()
            if broken { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.danger) }
        }
    }

    private var summary: String {
        guard let binding else { return "Not set" }
        let name = { (id: String) in model.store.set.profile(id: id)?.name ?? id }
        let base = ActionKind.summary(binding.defaultAction, profileName: name)
        let overrides = binding.overrides
        guard !overrides.isEmpty else { return base }
        let parts = GestureBinding.hostKeys.compactMap { key in overrides[key].map { "\(ProfileHosts(rawValue: key)?.title ?? key): \(ActionKind.summary($0, profileName: name))" } }
        let others = binding.defaultAction == nil ? [] : ["Others: \(base)"]
        return (parts + others).joined(separator: " · ")
    }
}

/// One gesture: the action for every host, and overrides for kinds of host.
struct BindingEditorView: View {
    @Environment(DongleModel.self) private var model
    let uid: UUID
    let gesture: ProfileGesture

    private var store: ProfileStore { model.store }
    private var index: Int? { store.set.profiles.firstIndex { $0.uid == uid } }
    private var binding: GestureBinding? { index.flatMap { store.set.profiles[$0][gesture] } }

    private func update(default action: String?, overrides: [String: String]) {
        guard let index else { return }
        var next = GestureBinding.make(default: action, overrides: overrides)
        if let buzz = binding?.buzz { if next == nil { next = .byHost([:]) }; next?.buzz = buzz }
        store.set.profiles[index][gesture] = next
    }

    private func context(_ key: String?) -> ActionContext {
        let base = "profiles[\(index ?? 0)].gestures.\(gesture.rawValue)"
        return ActionContext(ids: store.set.ids, allowsHold: gesture.allowsHold, allowsUnset: key == nil, path: key.map { "\(base).\($0)" } ?? base)
    }

    var body: some View {
        let overrides = binding?.overrides ?? [:]
        Form {
            Section {
                ActionEditor(action: Binding(get: { binding?.defaultAction }, set: { update(default: $0, overrides: overrides) }), context: context(nil))
            } header: {
                Text(overrides.isEmpty ? "Every host" : "Every other host")
            } footer: {
                Text(gesture.detail)
            }
            Section("When this gesture fires") {
                Picker("Buzz", selection: Binding(get: { binding?.buzz ?? "" }, set: { name in
                    guard let index else { return }
                    var next = binding ?? .byHost([:])
                    next.buzz = name.isEmpty ? nil : name
                    store.set.profiles[index][gesture] = next
                })) {
                    Text("Use set feedback").tag("")
                    ForEach(store.set.buzzNames, id: \.self) { Text($0).tag($0) }
                }
            }
            ForEach(GestureBinding.hostKeys.filter { $0 != "default" && overrides[$0] != nil } + overrides.keys.filter { !GestureBinding.hostKeys.contains($0) }.sorted(), id: \.self) { key in
                Section {
                    ActionEditor(action: Binding(get: { overrides[key] }, set: { value in
                        var next = overrides
                        next[key] = value
                        update(default: binding?.defaultAction, overrides: next)
                    }), context: context(key))
                    Button("Remove this override", role: .destructive) {
                        var next = overrides
                        next[key] = nil
                        update(default: binding?.defaultAction, overrides: next)
                    }
                    .font(.callout)
                } header: {
                    Label(ProfileHosts(rawValue: key)?.title ?? "\(key) (unknown)", systemImage: ProfileHosts(rawValue: key)?.symbol ?? "questionmark.circle")
                }
            }
            Section {
                let available = ProfileHosts.allCases.filter { overrides[$0.rawValue] == nil }
                if !available.isEmpty {
                    Menu {
                        ForEach(available, id: \.self) { hosts in
                            Button {
                                var next = overrides
                                next[hosts.rawValue] = binding?.defaultAction ?? "none"
                                update(default: binding?.defaultAction, overrides: next)
                            } label: { Label(hosts.title, systemImage: hosts.symbol) }
                        }
                    } label: {
                        Label("Different on a kind of host…", systemImage: "plus.circle")
                    }
                }
                if binding != nil {
                    Button("Clear this gesture", role: .destructive) { if let index { store.set.profiles[index][gesture] = nil } }
                }
            } footer: {
                Text("The most specific kind wins (Mac beats Any computer), then “every other host”. “Nothing” means nothing, even when there's a default.")
            }
        }
        .scrollContentBackground(.hidden)
        .screenBackground()
        .navigationTitle(gesture.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct SymbolPicker: View {
    @Binding var symbol: String
    let tint: Color

    var body: some View {
        HStack {
            Image(systemName: symbol.isEmpty ? GestureProfile.defaultSymbol : symbol)
                .font(.title2).foregroundStyle(tint).frame(width: 40)
            TextField("SF Symbol name", text: $symbol)
                .font(.callout.monospaced())
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(ProfileSymbols.suggestions, id: \.self) { name in
                    Button { symbol = name } label: {
                        Image(systemName: name)
                            .font(.title3)
                            .frame(width: 40, height: 40)
                            .background((symbol == name ? tint : Color.white).opacity(symbol == name ? 0.25 : 0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(name)
                }
            }
            .padding(.vertical, 2)
        }
    }
}

struct ColorSwatches: View {
    @Binding var color: String?

    var body: some View {
        HStack(spacing: 10) {
            ForEach(Theme.profileColors, id: \.hex) { swatch in
                Button { color = color == swatch.hex ? nil : swatch.hex } label: {
                    Circle()
                        .fill(Theme.color(hex: swatch.hex) ?? Theme.accent)
                        .frame(width: 28, height: 28)
                        .overlay(Circle().stroke(.white, lineWidth: color == swatch.hex ? 2.5 : 0))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(swatch.name)
            }
        }
        .padding(.vertical, 4)
    }
}

/// Mac apps that switch a computer to this profile while they're in front (np-appwatch tells the
/// dongle which app that is).
struct AppsSection: View {
    @Binding var apps: [String]
    var broken: Bool
    @State private var draft = ""
    @FocusState private var typing: Bool

    /// Common Mac apps, to pick without typing a bundle id.
    static let common: [(name: String, id: String)] = [
        ("Safari", "com.apple.Safari"), ("Chrome", "com.google.Chrome"), ("Arc", "company.thebrowser.Browser"),
        ("Firefox", "org.mozilla.firefox"), ("Edge", "com.microsoft.edgemac"), ("Xcode", "com.apple.dt.Xcode"),
        ("VS Code", "com.microsoft.VSCode"), ("Cursor", "com.todesktop.230313mzl4w4u92"), ("Terminal", "com.apple.Terminal"),
        ("Ghostty", "com.mitchellh.ghostty"), ("Slack", "com.tinyspeck.slackmacgap"), ("Teams", "com.microsoft.teams2"),
        ("Zoom", "us.zoom.xos"), ("Keynote", "com.apple.iWork.Keynote"), ("PowerPoint", "com.microsoft.Powerpoint"),
        ("Figma", "com.figma.Desktop"), ("Spotify", "com.spotify.client"), ("Music", "com.apple.Music"),
        ("Finder", "com.apple.finder"), ("Notes", "com.apple.Notes"),
    ]

    var body: some View {
        Section {
            ForEach(apps, id: \.self) { app in
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.common.first { $0.id.lowercased() == app.lowercased() }?.name ?? app)
                    if Self.common.contains(where: { $0.id.lowercased() == app.lowercased() }) {
                        Text(app).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                }
            }
            .onDelete { apps.remove(atOffsets: $0) }
            HStack {
                TextField("Bundle id, like com.google.Chrome", text: $draft)
                    .font(.body.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($typing)
                    .submitLabel(.done)
                    .onSubmit(add)
                    // What's typed counts without Return: leaving the field or the screen adds it.
                    .onChange(of: typing) { _, now in if !now { add() } }
                    .onDisappear(perform: add)
                Button("Add", action: add).disabled(!ProfileFormat.isValidApp(draft.trimmingCharacters(in: .whitespaces)))
            }
            let free = Self.common.filter { common in !apps.contains { $0.lowercased() == common.id.lowercased() } }
            if !free.isEmpty, apps.count < ProfileFormat.maxApps {
                Menu {
                    ForEach(free, id: \.id) { app in Button(app.name) { apps.append(app.id) } }
                } label: {
                    Label("Add a common app", systemImage: "plus.circle")
                }
            }
        } header: {
            Text("Apps (Mac)")
        } footer: {
            Text(broken
                 ? "An app can be in one profile only, at most \(ProfileFormat.maxApps) per profile, and only in a profile for computers."
                 : "With np-appwatch running on a Mac (brew install shlok-bhakta/np/np-appwatch), the Mac switches to this profile while one of these apps is in front, and back to its own profile for any other app. On the Mac, np-appwatch front prints the front app's bundle id.")
        }
    }

    private func add() {
        let app = draft.trimmingCharacters(in: .whitespaces)
        guard ProfileFormat.isValidApp(app), !apps.contains(where: { $0.lowercased() == app.lowercased() }) else { return }
        apps.append(app)
        draft = ""
    }
}
