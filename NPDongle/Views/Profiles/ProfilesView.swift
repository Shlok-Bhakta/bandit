import DongleProtocol
import SwiftUI
import UniformTypeIdentifiers

/// The phone's profile set: what's in it, whether the dongle has it, sending it, and moving it in
/// and out of the app as a `.npprofiles` file (to edit by hand or with an AI assistant).
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
        List {
            Section {
                TextField("Set name", text: Binding(get: { store.set.name ?? "" }, set: { store.set.name = $0.isEmpty ? nil : $0 }))
                    .font(.headline)
                SyncRow()
                ValidationRow(error: store.validation, size: store.size)
                if let error = store.saveError { Text(error).font(.footnote).foregroundStyle(Theme.danger) }
            }
            sendSection
            Section {
                ForEach(store.set.profiles, id: \.uid) { profile in
                    NavigationLink(value: ProfileRoute.profile(profile.uid)) {
                        ProfileRow(profile: profile, problem: problem(for: profile))
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
                Text("Every host has its own active profile. On the band: pinch, hold and let go, then write a menu letter to switch.")
            }
            Section {
                NavigationLink(value: ProfileRoute.menu) {
                    LabeledContent {
                        Text("\(store.set.menu.count) letters")
                    } label: {
                        Label("Letter menu", systemImage: "character.cursor.ibeam")
                    }
                }
                NavigationLink(value: ProfileRoute.start) { Label("Start profiles", systemImage: "flag") }
                NavigationLink(value: ProfileRoute.reference) { Label("Gestures and actions reference", systemImage: "book") }
            } header: {
                Text("The whole set")
            }
            fileSection
        }
        .darkList()
        .navigationTitle("Profiles")
        .navigationDestination(for: ProfileRoute.self) { route in
            switch route {
            case .profile(let uid): ProfileEditorView(uid: uid)
            case .menu: MenuEditorView()
            case .start: StartProfilesView()
            case .reference: ReferenceView()
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { EditButton() }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.npProfiles, .json]) { result in
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

    // MARK: sending

    private var sendSection: some View {
        Section {
            Button { uploader.send(store.set) } label: {
                HStack {
                    Label(model.syncState == .onDongle ? "Send again" : "Send to the dongle", systemImage: "arrow.up.circle.fill")
                    Spacer()
                    if uploader.isBusy { ProgressView().controlSize(.small) }
                }
            }
            .disabled(uploader.isBusy || store.validation != nil || !model.link.isReady || model.status?.supportsProfiles != true)
            uploadProgress
            Button { model.downloader.start() } label: {
                HStack {
                    Label("Get the dongle's set", systemImage: "arrow.down.circle")
                    Spacer()
                    if model.downloader.isBusy { ProgressView().controlSize(.small) }
                }
            }
            .disabled(model.downloader.isBusy || uploader.isBusy || !model.link.isReady || model.status?.supportsProfiles != true)
            if let error = model.downloader.error { Text(error).font(.caption).foregroundStyle(Theme.danger) }
            Button(role: .destructive) { confirmReset = true } label: { Label("Erase the dongle's set (back to built-in)", systemImage: "trash") }
                .disabled(uploader.isBusy || !model.link.isReady || model.status?.profileHash == ProfileFormat.builtinHash || model.status?.supportsProfiles != true)
        } footer: {
            Text("The app checks the set with the dongle's own rules, sends it minified (at most \(ProfileFormat.maxBytes) bytes), and waits for the dongle to report the same hash. Get the dongle's set when it was changed from somewhere else, like over USB.")
        }
    }

    @ViewBuilder
    private var uploadProgress: some View {
        switch uploader.phase {
        case .idle:
            EmptyView()
        case .sending:
            ProgressView(value: uploader.progress) { Text("Sending…").font(.caption) }
        case .confirming:
            HStack { ProgressView().controlSize(.small); Text("Waiting for the dongle to save it…").font(.callout) }
        case .done(let message):
            Label(message, systemImage: "checkmark.seal.fill").font(.callout).foregroundStyle(Theme.mint)
                .onTapGesture { uploader.dismiss() }
        case .failed(let reason):
            VStack(alignment: .leading, spacing: 4) {
                Label(reason, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(Theme.danger)
                Button("Dismiss") { uploader.dismiss() }.font(.footnote)
            }
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
            Text("To change the set with an AI assistant: Copy for an AI assistant (the rules and the file), paste it into the chat with what you want, copy its answer, then Paste JSON. You can also AirDrop or save a .\(ProfileFormat.fileExtension) file and open it with NP Dongle.")
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
    case menu, start, reference
}

struct ProfileRow: View {
    let profile: GestureProfile
    var problem = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: profile.displaySymbol)
                .font(.title3)
                .foregroundStyle(profile.tint)
                .frame(width: 36, height: 36)
                .background(profile.tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(profile.name.isEmpty ? "Untitled" : profile.name).font(.headline)
                    if problem { Image(systemName: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(Theme.danger) }
                }
                Text("\(profile.id) · \(profile.hostsSummary) · \(profile.gestures.count) gestures")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

/// The phone's set against the dongle's (status `ph`).
struct SyncRow: View {
    @Environment(DongleModel.self) private var model

    var body: some View {
        let state = model.syncState
        HStack {
            Label(state.title, systemImage: state.symbol)
                .foregroundStyle(state == .onDongle ? Theme.mint : state == .disconnected ? .secondary : Theme.warn)
            Spacer()
            Text(model.store.sha8).font(.caption.monospaced()).foregroundStyle(.secondary)
        }
        .font(.callout)
        if let hash = model.status?.profileHash, state == .different {
            Text("The dongle's set (\(hash)) isn't this phone's (\(model.store.sha8)). If it was changed somewhere else, get it first: sending replaces it.")
                .font(.caption).foregroundStyle(.secondary)
            Button { model.downloader.start() } label: {
                Label("Get the dongle's set onto this phone", systemImage: "arrow.down.circle.fill")
            }
            .disabled(model.downloader.isBusy)
        }
        if let error = model.status?.profileError {
            Label("Last upload refused: \(error)", systemImage: "xmark.octagon").font(.caption).foregroundStyle(Theme.danger)
        }
    }
}

/// The dongle's verdict on the set, with where the problem is.
struct ValidationRow: View {
    let error: ProfileError?
    let size: Int

    var body: some View {
        if let error {
            VStack(alignment: .leading, spacing: 4) {
                Label("The dongle would refuse this set", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout.weight(.semibold)).foregroundStyle(Theme.danger)
                ProblemText(error: error)
            }
        } else {
            HStack {
                Label("Valid", systemImage: "checkmark.shield").foregroundStyle(Theme.mint)
                Spacer()
                Text("\(size) of \(ProfileFormat.maxBytes) bytes").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            .font(.callout)
        }
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
