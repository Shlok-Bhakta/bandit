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

    /// The dongle's version of this profile, when the phone has edits it doesn't (nil: the same,
    /// unknown, or new here).
    private var dongleVersion: GestureProfile? {
        guard model.syncState == .phoneAhead, let theirs = model.dongleSet?.profile(id: profile.wrappedValue.id), theirs != profile.wrappedValue else { return nil }
        return theirs
    }

    private var isNew: Bool {
        model.syncState == .phoneAhead && model.dongleSet.map { $0.profile(id: profile.wrappedValue.id) == nil } == true
    }

    private func problem(_ index: Int) -> ProfileError? {
        guard let error = store.validation, error.path == "profiles[\(index)]" || error.path.hasPrefix("profiles[\(index)].") else { return nil }
        return error
    }

    private func form(_ index: Int) -> some View {
        let profile = profile
        let dongle = dongleVersion
        return Form {
            Section {
                header(profile, edited: dongle != nil)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
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
                            BindingEditorView(target: .profile(uid), gesture: gesture)
                        } label: {
                            GestureRow(gesture: gesture, binding: profile.wrappedValue[gesture], everywhere: store.set.everywhere[gesture.rawValue],
                                       broken: problem(index)?.path.hasPrefix("profiles[\(index)].gestures.\(gesture.rawValue)") == true,
                                       edited: dongle.map { $0[gesture] != profile.wrappedValue[gesture] } ?? false)
                        }
                    }
                }
            }
            Section {
                ForEach(ProfileGesture.band.filter { profile.wrappedValue[$0] != nil }, id: \.self) { gesture in
                    NavigationLink {
                        BindingEditorView(target: .profile(uid), gesture: gesture)
                    } label: {
                        GestureRow(gesture: gesture, binding: profile.wrappedValue[gesture], everywhere: store.set.everywhere[gesture.rawValue],
                                   broken: problem(index)?.path.hasPrefix("profiles[\(index)].gestures.\(gesture.rawValue)") == true,
                                   edited: dongle.map { $0[gesture] != profile.wrappedValue[gesture] } ?? false)
                    }
                }
                NavigationLink { BandEventsView(target: .profile(uid)) } label: { Label("Bind a band event…", systemImage: "plus.circle") }
                FirmwareFeatureNote()
            } header: { Text("Band events (experimental)") }
            Section {
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
                Text("The id is what menu letters and profile: actions use (1–16 of a–z, 0–9 and -, but not next, previous, back, home or app). Renaming it updates them.")
            }
            Section("Icon") {
                SymbolPicker(symbol: optional(profile.symbol), tint: profile.wrappedValue.tint)
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
                    Label { Text("Air mouse"); Text("Pinch, hold and move the wrist. iPhone: turn on AssistiveTouch").font(.caption) } icon: { Image(systemName: "computermouse") }
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
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    if let dongle {
                        Button { withAnimation { revert(to: dongle) } } label: { Label("Revert to the dongle's version", systemImage: "arrow.uturn.backward") }
                    }
                    if model.syncState == .onDongle, model.link.isReady {
                        Button { model.switchProfile(profile.wrappedValue.id) } label: { Label("Use on the active device", systemImage: "hand.point.right") }
                    }
                    Button { store.duplicate(index) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                        .disabled(store.set.profiles.count >= ProfileFormat.maxProfiles)
                    Button(role: .destructive) { confirmDelete = true } label: { Label("Delete profile", systemImage: "trash") }
                        .disabled(store.set.profiles.count <= 1)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
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

    private func header(_ profile: Binding<GestureProfile>, edited: Bool) -> some View {
        let tint = profile.wrappedValue.tint
        return GlowCard(tint: tint, cornerRadius: 22) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 14) {
                    SymbolTile(symbol: profile.wrappedValue.displaySymbol, tint: tint, size: 56)
                        .symbolEffect(.bounce, value: profile.wrappedValue.displaySymbol)
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("Name", text: profile.name)
                            .font(.system(.title2, design: .rounded, weight: .bold))
                            .submitLabel(.done)
                        HStack(spacing: 6) {
                            Text(profile.wrappedValue.id).font(.caption.monospaced()).foregroundStyle(.white.opacity(0.6))
                            if edited { Text("EDITED").badgeStyle(.white) }
                            if isNew { Text("NEW").badgeStyle(.white) }
                        }
                    }
                }
                if profile.wrappedValue.name.unicodeScalars.count > 24 {
                    Text("At most 24 characters.").font(.caption).foregroundStyle(Theme.danger)
                }
                ColorSwatches(color: profile.color)
            }
            .padding(16)
        }
        .padding(.vertical, 4)
        .animation(.easeInOut(duration: 0.3), value: profile.wrappedValue.color)
    }

    /// This profile as the dongle has it, keeping the id it has here.
    private func revert(to dongle: GestureProfile) {
        store.revert(.profile(dongle.id), to: model.dongleSet ?? store.set)
        draftID = dongle.id
    }

    @ViewBuilder
    private var idHint: some View {
        if !ProfileFormat.isValidID(draftID) {
            Text("1–16 of a–z, 0–9 and -").font(.caption).foregroundStyle(Theme.danger)
        } else if ProfileFormat.reservedIDs.contains(draftID) {
            Text("“\(draftID)” means something else in profile: actions: pick another id.").font(.caption).foregroundStyle(Theme.danger)
        } else if store.set.ids.contains(draftID) {
            Text("Another profile uses “\(draftID)”.").font(.caption).foregroundStyle(Theme.danger)
        } else {
            Button("Use “\(draftID)”") { commitID() }.font(.callout)
        }
    }

    private func commitID() {
        let old = profile.wrappedValue.id
        guard draftID != old else { return }
        guard ProfileFormat.isValidID(draftID), !ProfileFormat.reservedIDs.contains(draftID), !store.set.ids.contains(draftID) else { return }
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
    /// The set's `everywhere` binding for this gesture, which wins over a profile's own.
    var everywhere: GestureBinding? = nil
    var broken = false
    /// Differs from the dongle's.
    var edited = false

    var body: some View {
        HStack(spacing: 12) {
            SymbolTile(symbol: gesture.symbol, tint: binding == nil && everywhere == nil ? Color(white: 0.28) : gesture.tint, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(gesture.title)
                    .font(gesture.group == .band ? .callout.monospaced() : .body)
                    .lineLimit(1).minimumScaleFactor(0.75)
                if let everywhere {
                    Text("\(Image(systemName: "globe")) Everywhere: \(Self.summary(everywhere, profileName: name))")
                        .font(.caption).foregroundStyle(Theme.accent).lineLimit(2)
                    if binding != nil || !everywhere.coversEveryHost {
                        Text("Own: \(Self.summary(binding, profileName: name))").font(.caption).foregroundStyle(binding == nil ? .tertiary : .secondary).lineLimit(2)
                    }
                } else {
                    Text(Self.summary(binding, profileName: name)).font(.caption).foregroundStyle(binding == nil ? .tertiary : .secondary).lineLimit(2)
                }
            }
            Spacer()
            if broken { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.danger) }
            if edited {
                Circle().fill(Theme.accent).frame(width: 8, height: 8).accessibilityLabel("Edited")
            }
        }
    }

    private func name(_ id: String) -> String { model.store.set.profile(id: id)?.name ?? id }

    static func summary(_ binding: GestureBinding?, profileName name: (String) -> String) -> String {
        guard let binding else { return "Not set" }
        let base = ActionKind.summary(binding.defaultAction, profileName: name)
        let overrides = binding.overrides
        guard !overrides.isEmpty else { return base }
        let parts = GestureBinding.hostKeys.compactMap { key in overrides[key].map { "\(ProfileHosts(rawValue: key)?.title ?? key): \(ActionKind.summary($0, profileName: name))" } }
        let others = binding.defaultAction == nil ? [] : ["Others: \(base)"]
        return (parts + others).joined(separator: " · ")
    }
}

extension GestureBinding {
    /// Whether it has an action for every kind of host (as `everywhere`, a profile's own never runs).
    var coversEveryHost: Bool {
        DongleCommand.HostType.allCases.allSatisfy { type in action(for: type).map { $0 != "none" } ?? false }
    }
}

/// Whose bindings an editor changes: a profile's own, or the set's `everywhere`.
enum BindingTarget: Hashable {
    case profile(UUID)
    case everywhere
}

extension GestureProfileSet {
    subscript(target: BindingTarget, gesture: ProfileGesture) -> GestureBinding? {
        get {
            switch target {
            case .profile(let uid): profiles.first { $0.uid == uid }?[gesture]
            case .everywhere: everywhere[gesture.rawValue]
            }
        }
        set {
            switch target {
            case .profile(let uid): if let index = profiles.firstIndex(where: { $0.uid == uid }) { profiles[index][gesture] = newValue }
            case .everywhere: everywhere[gesture.rawValue] = newValue
            }
        }
    }

    /// The validator's path for a gesture's binding.
    func path(_ target: BindingTarget, _ gesture: ProfileGesture) -> String {
        switch target {
        case .profile(let uid): "profiles[\(profiles.firstIndex { $0.uid == uid } ?? 0)].gestures.\(gesture.rawValue)"
        case .everywhere: "everywhere.\(gesture.rawValue)"
        }
    }
}

/// One gesture: the action for every host, and overrides for kinds of host.
struct BindingEditorView: View {
    @Environment(DongleModel.self) private var model
    let target: BindingTarget
    let gesture: ProfileGesture

    private var store: ProfileStore { model.store }
    private var binding: GestureBinding? { store.set[target, gesture] }

    private func update(default action: String?, overrides: [String: String]) {
        var next = GestureBinding.make(default: action, overrides: overrides)
        if let buzz = binding?.buzz { if next == nil { next = .byHost([:]) }; next?.buzz = buzz }
        store.set[target, gesture] = next
    }

    private func context(_ key: String?) -> ActionContext {
        let base = store.set.path(target, gesture)
        return ActionContext(ids: store.set.ids, allowsHold: gesture.allowsHold, allowsPoint: gesture.allowsPoint, allowsUnset: key == nil, path: key.map { "\(base).\($0)" } ?? base)
    }

    var body: some View {
        let overrides = binding?.overrides ?? [:]
        Form {
            if case .profile = target, let everywhere = store.set.everywhere[gesture.rawValue] {
                Section {
                    Label("Everywhere: \(GestureRow.summary(everywhere, profileName: { store.set.profile(id: $0)?.name ?? $0 }))", systemImage: "globe")
                        .foregroundStyle(Theme.accent)
                    NavigationLink("Edit the Everywhere binding") { BindingEditorView(target: .everywhere, gesture: gesture) }
                } footer: {
                    Text(everywhere.coversEveryHost
                         ? "The set's Everywhere binding wins on every host, so this profile's own never runs."
                         : "The set's Everywhere binding wins for the kinds of host it has an action for; this profile's own runs on the others.")
                }
            }
            Section {
                ActionEditor(action: Binding(get: { binding?.defaultAction }, set: { update(default: $0, overrides: overrides) }), context: context(nil))
            } header: {
                Text(overrides.isEmpty ? "Every host" : "Every other host")
            } footer: {
                Text(gesture.detail)
            }
            Section("When this gesture fires") {
                Picker("Buzz", selection: Binding(get: { binding?.buzz ?? "" }, set: { name in
                    var next = binding ?? .byHost([:])
                    next.buzz = name.isEmpty ? nil : name
                    store.set[target, gesture] = next
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
                    Button(target == .everywhere ? "Remove from Everywhere" : "Clear this gesture", role: .destructive) { store.set[target, gesture] = nil }
                }
            } footer: {
                Text(target == .everywhere
                     ? "The most specific kind wins (Mac beats Any computer), then “every other host”. Kinds of host with no action here (or “Nothing”) keep each profile's own binding."
                     : "The most specific kind wins (Mac beats Any computer), then “every other host”. “Nothing” means nothing, even when there's a default.")
            }
        }
        .scrollContentBackground(.hidden)
        .screenBackground()
        .navigationTitle(target == .everywhere ? "\(gesture.title) everywhere" : gesture.title)
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
        HStack(spacing: 0) {
            ForEach(Theme.profileColors, id: \.hex) { swatch in
                Button { color = color == swatch.hex ? nil : swatch.hex } label: {
                    Circle()
                        .fill(Theme.color(hex: swatch.hex) ?? Theme.accent)
                        .frame(width: 28, height: 28)
                        .overlay(Circle().strokeBorder(.white, lineWidth: color == swatch.hex ? 2.5 : 0))
                        .overlay { if color == swatch.hex { Image(systemName: "checkmark").font(.caption2.weight(.heavy)).foregroundStyle(.white) } }
                        .scaleEffect(color == swatch.hex ? 1.12 : 1)
                        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: color)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .accessibilityLabel(swatch.name)
                .accessibilityAddTraits(color == swatch.hex ? .isSelected : [])
            }
        }
        .padding(.vertical, 4)
        .sensoryFeedback(.selection, trigger: color)
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
