import DongleProtocol
import SwiftUI

/// The bar under every Profiles screen: what the dongle doesn't have yet, and sending it (or
/// getting and merging the dongle's when it changed somewhere else).
struct SyncBar: View {
    @Environment(DongleModel.self) private var model
    @State private var reviewing = false
    @State private var confirmReplace = false
    @State private var keyboard = false

    private var store: ProfileStore { model.store }
    private var uploader: ProfileUploader { model.uploader }

    var body: some View {
        Group {
            if !keyboard, let content {
                bar(content)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: content?.id)
        .sheet(isPresented: $reviewing) { NavigationStack { ChangesView() } }
        .confirmationDialog("Replace the dongle's set with this iPhone's?", isPresented: $confirmReplace, titleVisibility: .visible) {
            Button("Replace it", role: .destructive) { model.sendProfiles() }
        } message: {
            Text("Whatever changed on the dongle is lost. Merge keeps both sides' changes.")
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in keyboard = true }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboard = false }
        .sensoryFeedback(.success, trigger: uploader.phase) { _, phase in if case .done = phase { true } else { false } }
        .sensoryFeedback(.error, trigger: uploader.phase) { _, phase in if case .failed = phase { true } else { false } }
    }

    /// What the bar says, and its buttons.
    private struct Content {
        enum Action { case send, merge, get, retry, replace, dismiss }
        var id: String
        var symbol: String
        var tint: Color
        var title: String
        var detail: String
        var primary: (title: String, action: Action)?
        var secondary: (title: String, action: Action)?
        var progress: Double?
        var disabled = false
    }

    private var content: Content? {
        let changes = model.unsentChanges
        switch uploader.phase {
        case .sending:
            return Content(id: "sending", symbol: "arrow.up.circle", tint: Theme.accent, title: "Sending to the dongle…",
                           detail: "Keep the iPhone close", progress: uploader.progress)
        case .confirming:
            return Content(id: "confirming", symbol: "checkmark.circle", tint: Theme.accent, title: "Saving on the dongle…",
                           detail: "Waiting for it to confirm", progress: 1)
        case .failed(let reason):
            return Content(id: "failed", symbol: "exclamationmark.triangle.fill", tint: Theme.danger, title: "Not sent",
                           detail: reason, primary: ("Retry", .retry), secondary: ("Dismiss", .dismiss))
        case .idle, .done:
            break
        }
        let problem = store.validation.map { "Fix first: \(friendlyPath($0.path))\($0.message)" }
        switch model.syncState {
        case .phoneAhead:
            return Content(id: "ahead", symbol: "arrow.up.circle.fill", tint: problem == nil ? Theme.accent : Theme.warn,
                           title: changes.count == 1 ? "1 change to send" : "\(changes.count) changes to send",
                           detail: problem ?? changes.prefix(3).map { ChangeText.title($0, in: store.set, or: model.dongleSet) }.joined(separator: " · "),
                           primary: ("Send", .send), disabled: problem != nil)
        case .dongleAhead:
            return Content(id: "behind", symbol: "arrow.down.circle.fill", tint: Theme.mint, title: "The dongle has a newer set",
                           detail: "It was changed somewhere else. Get it to see what changed.", primary: ("Get", .get))
        case .diverged:
            return Content(id: "diverged", symbol: "arrow.triangle.merge", tint: Theme.warn, title: "Phone and dongle differ",
                           detail: store.synced == nil ? "This iPhone hasn't seen the dongle's set. Merge to pick what to keep." : "Both changed since they last matched. Merge to pick what to keep.",
                           primary: ("Merge", .merge), secondary: ("Replace", .replace), disabled: model.downloader.isBusy)
        case .disconnected where store.synced != nil && !store.unchangedSinceSync:
            return Content(id: "offline", symbol: "iphone", tint: .gray, title: "Saved on this iPhone",
                           detail: "Connect the dongle to send your changes.")
        default:
            return nil
        }
    }

    private func friendlyPath(_ path: String) -> String {
        guard !path.isEmpty else { return "" }
        if let match = path.firstMatch(of: /^profiles\[(\d+)\]/), let index = Int(match.1), store.set.profiles.indices.contains(index) {
            return "\(store.set.profiles[index].name): "
        }
        return "\(path): "
    }

    private func bar(_ content: Content) -> some View {
        HStack(spacing: 12) {
            Button { if content.id == "ahead" { reviewing = true } } label: {
                HStack(spacing: 12) {
                    ZStack {
                        if let progress = content.progress {
                            Circle().stroke(content.tint.opacity(0.25), lineWidth: 3)
                            Circle().trim(from: 0, to: progress).stroke(content.tint, style: StrokeStyle(lineWidth: 3, lineCap: .round)).rotationEffect(.degrees(-90))
                        }
                        Image(systemName: content.symbol)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(content.tint)
                            .symbolEffect(.pulse, isActive: content.progress != nil)
                    }
                    .frame(width: 34, height: 34)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 4) {
                            Text(content.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                            if content.id == "ahead" { Image(systemName: "chevron.up").font(.caption2.weight(.bold)).foregroundStyle(.secondary) }
                        }
                        Text(content.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if let secondary = content.secondary {
                Button(secondary.title) { run(secondary.action) }
                    .buttonStyle(.bordered).tint(.gray).controlSize(.small)
                    .fixedSize()
            }
            if let primary = content.primary {
                Button { run(primary.action) } label: { Text(primary.title).fontWeight(.semibold).padding(.horizontal, 4) }
                    .buttonStyle(.borderedProminent).tint(content.tint).controlSize(.small)
                    .fixedSize()
                    .disabled(content.disabled || !model.link.isReady)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(content.tint.opacity(0.35), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
        .padding(.horizontal, 12).padding(.bottom, 6)
    }

    private func run(_ action: Content.Action) {
        switch action {
        case .send, .retry: model.sendProfiles()
        case .merge, .get: model.downloader.start()
        case .replace: confirmReplace = true
        case .dismiss: uploader.dismiss()
        }
    }
}

/// Everything the phone has that the dongle doesn't, each with a way back.
struct ChangesView: View {
    @Environment(DongleModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDiscard = false

    private var store: ProfileStore { model.store }

    var body: some View {
        let changes = model.unsentChanges
        let dongle = model.dongleSet
        List {
            if changes.isEmpty {
                let state = model.syncState
                Group {
                    if state == .onDongle {
                        ContentUnavailableView("Nothing to send", systemImage: "checkmark.seal", description: Text("The dongle has everything on this iPhone."))
                    } else {
                        ContentUnavailableView(state.title, systemImage: state.symbol, description: Text("Changes show here while the dongle is connected and runs a set this iPhone knows."))
                    }
                }
                .listRowBackground(Color.clear)
            } else {
                if let error = store.validation {
                    Section {
                        Label("The dongle would refuse this set", systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.danger)
                        ProblemText(error: error)
                    }
                }
                Section {
                    ForEach(changes, id: \.self) { part in
                        ChangeRow(part: part, phone: store.set, other: dongle)
                            .swipeActions {
                                if let dongle { Button("Revert") { withAnimation { store.revert(part, to: dongle) } }.tint(Theme.warn) }
                            }
                            .contextMenu {
                                if let dongle {
                                    Button { withAnimation { store.revert(part, to: dongle) } } label: { Label("Revert to the dongle's", systemImage: "arrow.uturn.backward") }
                                }
                            }
                    }
                } footer: {
                    Text("Swipe a change to put it back as the dongle has it.")
                }
                Section {
                    Button(role: .destructive) { confirmDiscard = true } label: {
                        Label("Discard all changes", systemImage: "arrow.uturn.backward.circle").foregroundStyle(Theme.danger)
                    }
                }
            }
        }
        .darkList()
        .navigationTitle("Changes")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            if !changes.isEmpty {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") { model.sendProfiles(); dismiss() }
                        .fontWeight(.semibold)
                        .disabled(store.validation != nil || !model.link.isReady || model.uploader.isBusy)
                }
            }
        }
        .confirmationDialog("Discard every change?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard changes", role: .destructive) { model.discardChanges(); dismiss() }
        } message: {
            Text("This iPhone's set goes back to what the dongle runs.")
        }
    }
}

/// One changed part: what it is, and how this side differs from the other.
struct ChangeRow: View {
    @Environment(DongleModel.self) private var model
    let part: ProfileSetPart
    let phone: GestureProfileSet
    let other: GestureProfileSet?

    var body: some View {
        HStack(spacing: 12) {
            SymbolTile(symbol: ChangeText.symbol(part, in: phone, or: other), tint: ChangeText.tint(part, in: phone, or: other), size: 32)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(ChangeText.title(part, in: phone, or: other)).font(.headline)
                    let kind = ChangeText.kind(part, phone: phone, other: other)
                    Text(kind.label).badgeStyle(kind.tint)
                }
                Text(ChangeText.detail(part, phone: phone, other: other)).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
        }
        .padding(.vertical, 2)
    }
}

/// Words for changed parts.
enum ChangeText {
    enum Kind {
        case edited, added, removed
        var label: String {
            switch self {
            case .edited: "EDITED"
            case .added: "NEW"
            case .removed: "DELETED"
            }
        }
        var tint: Color {
            switch self {
            case .edited: Theme.accent
            case .added: Theme.mint
            case .removed: Theme.danger
            }
        }
    }

    static func kind(_ part: ProfileSetPart, phone: GestureProfileSet, other: GestureProfileSet?) -> Kind {
        guard case .profile(let id) = part, let other else { return .edited }
        switch (phone.profile(id: id), other.profile(id: id)) {
        case (_?, nil): return .added
        case (nil, _?): return .removed
        default: return .edited
        }
    }

    static func title(_ part: ProfileSetPart, in phone: GestureProfileSet, or other: GestureProfileSet?) -> String {
        switch part {
        case .name: "Set name"
        case .menu: "Letter menu"
        case .start: "Start profiles"
        case .everywhere: "Everywhere"
        case .buzzes: "Buzz patterns"
        case .feedback: "Feedback"
        case .order: "Profile order"
        case .profile(let id): (phone.profile(id: id) ?? other?.profile(id: id)).map { $0.name.isEmpty ? id : $0.name } ?? id
        }
    }

    static func symbol(_ part: ProfileSetPart, in phone: GestureProfileSet, or other: GestureProfileSet?) -> String {
        switch part {
        case .name: "textformat"
        case .menu: "character.cursor.ibeam"
        case .start: "flag.fill"
        case .everywhere: "globe"
        case .buzzes: "waveform"
        case .feedback: "hand.tap.fill"
        case .order: "arrow.up.arrow.down"
        case .profile(let id): (phone.profile(id: id) ?? other?.profile(id: id))?.displaySymbol ?? GestureProfile.defaultSymbol
        }
    }

    static func tint(_ part: ProfileSetPart, in phone: GestureProfileSet, or other: GestureProfileSet?) -> Color {
        if case .profile(let id) = part { return (phone.profile(id: id) ?? other?.profile(id: id))?.tint ?? Theme.accent }
        return part == .everywhere ? Theme.mint : Theme.violet
    }

    /// How `phone` differs from `other` in `part`.
    static func detail(_ part: ProfileSetPart, phone: GestureProfileSet, other: GestureProfileSet?) -> String {
        guard let other else { return summary(part, in: phone) }
        switch part {
        case .profile(let id):
            switch (phone.profile(id: id), other.profile(id: id)) {
            case (let mine?, let theirs?): return "Changed: " + profileChanges(mine, theirs).joined(separator: ", ")
            case (let mine?, nil): return summary(.profile(mine.id), in: phone)
            default: return "Deleted"
            }
        case .menu:
            let letters = Set(phone.menu.keys).union(other.menu.keys).filter { phone.menu[$0] != other.menu[$0] }.sorted()
            return "Letters " + letters.map { $0.uppercased() }.joined(separator: ", ")
        case .everywhere:
            let names = Set(phone.everywhere.keys).union(other.everywhere.keys).filter { phone.everywhere[$0] != other.everywhere[$0] }.sorted()
            return names.map { ProfileGesture(rawValue: $0)?.title ?? $0 }.joined(separator: ", ")
        case .buzzes, .feedback:
            let mine = part == .buzzes ? phone.buzzes : phone.feedback, theirs = part == .buzzes ? other.buzzes : other.feedback
            return Set(mine.keys).union(theirs.keys).filter { mine[$0] != theirs[$0] }.sorted().joined(separator: ", ")
        default:
            return summary(part, in: phone)
        }
    }

    /// What `set` has for `part`, in a line.
    static func summary(_ part: ProfileSetPart, in set: GestureProfileSet) -> String {
        switch part {
        case .name: return set.name ?? "No name"
        case .menu: return set.menu.isEmpty ? "No letters" : "\(set.menu.count) letters: " + set.menu.keys.sorted().map { $0.uppercased() }.joined(separator: " ")
        case .start:
            let parts = GestureProfileSet.startGroups.compactMap { group in set.start[group].map { "\(group.capitalized): \(set.profile(id: $0)?.name ?? $0)" } }
            return parts.isEmpty ? "Automatic" : parts.joined(separator: " · ")
        case .everywhere:
            return set.everywhere.isEmpty ? "None" : set.everywhere.keys.sorted().map { ProfileGesture(rawValue: $0)?.title ?? $0 }.joined(separator: ", ")
        case .buzzes: return set.buzzes.isEmpty ? "None" : set.buzzes.keys.sorted().joined(separator: ", ")
        case .feedback: return set.feedback.isEmpty ? "Defaults" : set.feedback.map { "\($0.key): \($0.value)" }.sorted().joined(separator: ", ")
        case .order: return set.profiles.map(\.name).joined(separator: " · ")
        case .profile(let id):
            guard let profile = set.profile(id: id) else { return "Not there" }
            return "“\(profile.name)” · \(profile.gestures.count) gestures · \(profile.hostsSummary)"
        }
    }

    /// The fields two versions of a profile differ in.
    static func profileChanges(_ a: GestureProfile, _ b: GestureProfile) -> [String] {
        var changes: [String] = []
        if a.name != b.name { changes.append("name") }
        if a.buzz != b.buzz || a.buzzName != b.buzzName { changes.append("switch buzz") }
        if a.hosts != b.hosts { changes.append("who may use it") }
        if a.typing != b.typing || a.pointer != b.pointer { changes.append("behaviour") }
        if a.apps != b.apps { changes.append("apps") }
        if a.symbol != b.symbol || a.color != b.color || a.description != b.description { changes.append("look") }
        let gestures = Set(a.gestures.keys).union(b.gestures.keys).filter { a.gestures[$0] != b.gestures[$0] }
        let named = ProfileGesture.allCases.filter { gestures.contains($0.rawValue) }.map(\.title) + gestures.filter { ProfileGesture(rawValue: $0) == nil }.sorted()
        changes += named.prefix(4)
        if named.count > 4 { changes.append("\(named.count - 4) more gestures") }
        if a.extra != b.extra { changes.append("other fields") }
        return changes.isEmpty ? ["id"] : changes
    }
}
