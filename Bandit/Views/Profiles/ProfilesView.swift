import DongleProtocol
import SwiftUI
import UniformTypeIdentifiers

/// The phone's profile set: what's in it, whether the dongle has it, sending it, and moving it in
/// and out of the app as a `.bandit` file (to edit by hand or with an AI assistant).
struct ProfilesView: View {
    @Environment(DongleModel.self) private var model
    @State private var importing = false
    @State private var confirmReset = false
    @State private var confirmRestore = false
    @State private var copied: String?

    private var store: ProfileStore { model.store }
    private var uploader: ProfileUploader { model.uploader }

    var body: some View {
        @Bindable var store = model.store
        let dongle = model.syncState == .phoneAhead ? model.dongleSet : nil
        List {
            Section {
                SetHeader()
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
            Section {
                ForEach(store.set.profiles, id: \.uid) { profile in
                    NavigationLink(value: ProfileRoute.profile(profile.uid)) {
                        ProfileRow(profile: profile, problem: problem(for: profile),
                                   change: dongle.flatMap { dongle in
                                       guard let theirs = dongle.profile(id: profile.id) else { return .added }
                                       return theirs == profile ? nil : .edited
                                   })
                    }
                    .contextMenu {
                        Button { duplicate(profile) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                            .disabled(store.set.profiles.count >= ProfileFormat.maxProfiles)
                        if model.link.isReady, model.status?.supportsProfiles == true, model.syncState == .onDongle {
                            Button { model.switchProfile(profile.id) } label: { Label("Use on the active host", systemImage: "hand.point.right") }
                        }
                    }
                }
                .onMove { store.set.profiles.move(fromOffsets: $0, toOffset: $1) }
                .onDelete { store.delete(at: $0) }
                if store.set.profiles.count < ProfileFormat.maxProfiles {
                    Button { _ = store.addProfile() } label: { Label("New profile", systemImage: "plus.circle") }
                }
            } header: {
                Text("Profiles (\(store.set.profiles.count) of \(ProfileFormat.maxProfiles))")
            } footer: {
                Text("Every host has its own active profile; its start profile is home. On the band: pinch, hold and let go, then write a menu letter to switch, or bind gestures to profile actions (Back returns to where you came from, and home in the end).")
            }
            Section {
                NavigationLink { BuzzesView() } label: { Label("Buzzes", systemImage: "waveform") }
                NavigationLink { FeedbackView() } label: { Label("Feedback", systemImage: "hand.tap") }
                NavigationLink(value: ProfileRoute.menu) {
                    LabeledContent {
                        Text("\(store.set.menu.count) letters")
                    } label: {
                        Label("Letter menu", systemImage: "character.cursor.ibeam")
                    }
                }
                NavigationLink(value: ProfileRoute.everywhere) {
                    LabeledContent {
                        HStack(spacing: 6) {
                            if store.validation?.path.hasPrefix("everywhere.") == true {
                                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.danger)
                            }
                            Text("\(store.set.everywhere.count) gestures")
                        }
                    } label: {
                        Label("Everywhere", systemImage: "globe")
                    }
                }
                NavigationLink(value: ProfileRoute.start) { Label("Start profiles", systemImage: "flag") }
                NavigationLink(value: ProfileRoute.reference) { Label("Gestures and actions reference", systemImage: "book") }
            } header: {
                Text("The whole set")
            }
            Section("Discover") {
                NavigationLink { GestureLabView() } label: { Label("Gesture lab", systemImage: "waveform.path") }
            }
            dongleSection
            fileSection
        }
        .darkList()
        .navigationTitle("Profiles")
        .navigationDestination(for: ProfileRoute.self) { route in
            switch route {
            case .profile(let uid): ProfileEditorView(uid: uid)
            case .menu: MenuEditorView()
            case .everywhere: EverywhereView()
            case .start: StartProfilesView()
            case .reference: ReferenceView()
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { EditButton() }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.banditProfiles, .legacyProfiles, .json]) { result in
            switch result {
            case .success(let url): model.pendingImport = ProfileStore.candidate(url: url)
            case .failure(let error): model.pendingImport = .init(source: "Files", set: nil, error: ProfileError("", error.localizedDescription))
            }
        }
        .confirmationDialog("Erase the dongle's set?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Erase it", role: .destructive) { uploader.resetDongle() }
        } message: {
            Text("The dongle deletes its set and goes back to the built-in profiles. Nothing comes to this phone: to copy the dongle's set here, use Get the dongle's set.")
        }
        .confirmationDialog("Replace this phone's set with the built-in one?", isPresented: $confirmRestore, titleVisibility: .visible) {
            Button("Restore built-in profiles", role: .destructive) { store.restoreBuiltin() }
        } message: {
            Text("Your edits on this phone are lost unless you export them first. The dongle doesn't change until you send.")
        }
    }

    private func duplicate(_ profile: GestureProfile) {
        if let index = store.set.profiles.firstIndex(where: { $0.uid == profile.uid }) { store.duplicate(index) }
    }

    private func problem(for profile: GestureProfile) -> Bool {
        guard let path = store.validation?.path, let index = store.set.profiles.firstIndex(where: { $0.uid == profile.uid }) else { return false }
        return path == "profiles[\(index)]" || path.hasPrefix("profiles[\(index)].")
    }

    // MARK: the dongle

    private var dongleSection: some View {
        Section {
            Button { model.downloader.start() } label: {
                HStack {
                    Label("Get the dongle's set", systemImage: "arrow.down.circle")
                    Spacer()
                    if model.downloader.isBusy { ProgressView().controlSize(.small) }
                }
            }
            .disabled(model.downloader.isBusy || uploader.isBusy || !model.link.isReady || model.status?.supportsProfiles != true)
            if let error = model.downloader.error { Text(error).font(.caption).foregroundStyle(Theme.danger) }
            if model.syncState == .onDongle {
                Button { model.sendProfiles() } label: { Label("Send again", systemImage: "arrow.up.circle") }
                    .disabled(uploader.isBusy || store.validation != nil || !model.link.isReady)
            }
            Button(role: .destructive) { confirmReset = true } label: { Label("Erase the dongle's set (back to built-in)", systemImage: "trash") }
                .disabled(uploader.isBusy || !model.link.isReady || model.status?.profileHash == ProfileFormat.builtinHash || model.status?.supportsProfiles != true)
        } header: {
            Text("Dongle")
        } footer: {
            Text("Edits save on this iPhone as you make them; the bar at the bottom sends them to the dongle. Get brings the dongle's set here, merging it with yours when both changed.")
        }
    }

    // MARK: files

    private var fileSection: some View {
        Section {
            ShareLink(item: ProfilesFile(data: store.set.prettyData, name: store.set.name ?? "profiles"),
                      preview: SharePreview("\(store.set.name ?? "Profiles").\(ProfileFormat.fileExtension)")) {
                Label("Share as a .\(ProfileFormat.fileExtension) file", systemImage: "square.and.arrow.up")
            }
            Button { copy(String(decoding: store.set.prettyData, as: UTF8.self), "json") } label: {
                Label(copied == "json" ? "Copied" : "Copy JSON", systemImage: copied == "json" ? "checkmark" : "doc.on.doc")
            }
            Button { copy(assistantText, "assistant") } label: {
                Label(copied == "assistant" ? "Copied" : "Copy for an AI assistant", systemImage: copied == "assistant" ? "checkmark" : "sparkles")
            }
            Button { importing = true } label: { Label("Import a file…", systemImage: "doc.badge.plus") }
            Button { model.pasteProfiles() } label: { Label("Paste JSON", systemImage: "doc.on.clipboard") }
            Button(role: .destructive) { confirmRestore = true } label: { Label("Restore built-in profiles", systemImage: "arrow.counterclockwise") }
                .disabled(store.isBuiltin)
        } header: {
            Text("File")
        } footer: {
            Text("To change the set with an AI assistant: Copy for an AI assistant (the rules and the file), paste it into the chat with what you want, copy its answer, then Paste JSON. You can also AirDrop or save a .\(ProfileFormat.fileExtension) file and open it with Bandit.")
        }
    }

    /// The format's rules, then the file: paste into an assistant, ask for a change, paste the
    /// answer back with Paste JSON.
    private var assistantText: String {
        "\(ProfileFormat.assistantBrief)\n\nThe file:\n\n```json\n\(String(decoding: store.set.prettyData, as: UTF8.self))```\n"
    }

    private func copy(_ text: String, _ what: String) {
        Clipboard.copy(text)
        copied = what
        Task {
            try? await Task.sleep(for: .seconds(2))
            copied = nil
        }
    }
}

enum ProfileRoute: Hashable {
    case profile(UUID)
    case menu, everywhere, start, reference
}

struct ProfileRow: View {
    let profile: GestureProfile
    var problem = false
    /// How it differs from the dongle's (nil: the same, or unknown).
    var change: ChangeText.Kind? = nil

    var body: some View {
        HStack(spacing: 12) {
            SymbolTile(symbol: profile.displaySymbol, tint: profile.tint, size: 38)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(profile.name.isEmpty ? "Untitled" : profile.name).font(.headline)
                    if problem { Image(systemName: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(Theme.danger) }
                    if let change { Text(change.label).badgeStyle(change.tint) }
                }
                Text("\(profile.id) · \(profile.hostsSummary) · \(profile.gestures.count) gestures")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

/// The set: its name, whether the dongle has it, and whether the dongle would take it.
struct SetHeader: View {
    @Environment(DongleModel.self) private var model

    var body: some View {
        @Bindable var store = model.store
        let state = model.syncState
        let tint: Color = switch state {
        case .onDongle: Theme.mint
        case .disconnected, .unsupported: .gray
        case .phoneAhead, .dongleAhead: Theme.accent
        case .diverged: Theme.warn
        }
        GlowCard(tint: store.validation == nil ? tint : Theme.danger, cornerRadius: 22) {
            VStack(alignment: .leading, spacing: 12) {
                TextField("Name this set", text: Binding(get: { store.set.name ?? "" }, set: { store.set.name = $0.isEmpty ? nil : $0 }))
                    .font(.system(.title2, design: .rounded, weight: .bold))
                    .submitLabel(.done)
                HStack(spacing: 8) {
                    Label(state.title, systemImage: state.symbol)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(tint.opacity(0.45), in: Capsule())
                        .foregroundStyle(.white)
                        .contentTransition(.symbolEffect(.replace))
                    Spacer()
                    Text("\(store.set.profiles.count) profiles · \(store.size * 100 / ProfileFormat.maxBytes)% full")
                        .font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.6))
                }
                ProgressView(value: Double(min(store.size, ProfileFormat.maxBytes)), total: Double(ProfileFormat.maxBytes))
                    .tint(store.size > ProfileFormat.maxBytes * 9 / 10 ? Theme.warn : .white.opacity(0.7))
                if let error = store.validation {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("The dongle would refuse this set", systemImage: "exclamationmark.triangle.fill")
                            .font(.callout.weight(.semibold)).foregroundStyle(Theme.danger)
                        ProblemText(error: error)
                    }
                }
                if let error = model.status?.profileError {
                    Label("Last upload refused: \(error)", systemImage: "xmark.octagon").font(.caption).foregroundStyle(Theme.danger)
                }
                if let error = store.saveError { Text(error).font(.footnote).foregroundStyle(Theme.danger) }
            }
            .padding(18)
        }
        .padding(.vertical, 4)
    }
}

struct ProblemText: View {
    let error: ProfileError

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if !error.path.isEmpty { Text(error.path).font(.caption.monospaced()).foregroundStyle(Theme.warn) }
            Text(error.message).font(.caption).foregroundStyle(.secondary)
        }
        .textSelection(.enabled)
    }
}
