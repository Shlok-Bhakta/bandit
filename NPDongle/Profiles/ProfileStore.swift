import BandLogging
import DongleProtocol
import Foundation
import Observation

/// The phone's own profile set: one `.npprofiles` file in the app's Documents (pretty-printed, so
/// it reads well in the Files app too), edited in place and saved shortly after each change.
@MainActor
@Observable
final class ProfileStore {
    /// A file (or pasted text) on its way in, waiting for the user to look at it.
    struct Candidate: Identifiable {
        let id = UUID()
        /// Where it came from, for the sheet's title ("Clipboard", a file name).
        let source: String
        /// The set, when the file could be read at all.
        let set: GestureProfileSet?
        /// What the dongle would say about it (nil: it would take it).
        let error: ProfileError?
        /// Read off the dongle: its hash for this set (`ph`), which the phone's copy won't share
        /// (the phone writes JSON its own way).
        var dongleHash: String? = nil
    }

    static let fileName = "profiles.\(ProfileFormat.fileExtension)"

    var set: GestureProfileSet {
        didSet {
            guard set != oldValue else { return }
            refresh()
            scheduleSave()
        }
    }
    /// The dongle's verdict on `set`, its hash and minified size, kept current with every edit.
    private(set) var validation: ProfileError?
    private(set) var sha8 = ""
    private(set) var size = 0
    private(set) var saveError: String?

    @ObservationIgnored private var saveTask: Task<Void, Never>?

    /// The set the dongle was last seen running, with the dongle's hash for it (`ph`): what the
    /// phone's edits are compared with, and the common version when the two need merging.
    struct Synced {
        let set: GestureProfileSet
        let hash: String
    }

    private(set) var synced: Synced? {
        didSet {
            syncedSha8 = synced?.set.sha8
            saveSynced()
        }
    }
    private var syncedSha8: String?
    private static let syncedHashKey = "profiles.syncedHash"
    /// Before build 15: (the dongle's hash, the phone's) for a set taken from the dongle.
    private static let dongleCopyKey = "profiles.dongleCopy"

    /// Whether the dongle's set (status `ph`) is this phone's.
    func isOnDongle(_ hash: String) -> Bool {
        hash == sha8 || (hash == ProfileFormat.builtinHash && isBuiltin) || (synced?.hash == hash && syncedSha8 == sha8)
    }

    /// The dongle's set when the app knows it: the built-in one, or the one last synced.
    func dongleSet(hash: String) -> GestureProfileSet? {
        if isOnDongle(hash) { return set }
        if hash == ProfileFormat.builtinHash { return .builtin }
        return synced?.hash == hash ? synced?.set : nil
    }

    /// The status says the dongle runs this phone's set: remember it as the synced version.
    func noteDongle(hash: String) {
        guard isOnDongle(hash), synced?.hash != hash || syncedSha8 != sha8 else { return }
        synced = Synced(set: set, hash: hash)
    }

    /// The dongle took (or sent) `set`, which it hashes as `hash`.
    func markSynced(_ set: GestureProfileSet, hash: String) {
        synced = Synced(set: set, hash: hash)
    }

    /// Whether the phone's set is still the one last synced (nothing edited since).
    var unchangedSinceSync: Bool { syncedSha8 == sha8 }

    private static var syncedURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("synced.\(ProfileFormat.fileExtension)")
    }

    private func saveSynced() {
        UserDefaults.standard.set(synced?.hash, forKey: Self.syncedHashKey)
        UserDefaults.standard.removeObject(forKey: Self.dongleCopyKey)
        do {
            if let synced {
                try FileManager.default.createDirectory(at: Self.syncedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try synced.set.prettyData.write(to: Self.syncedURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            } else {
                try? FileManager.default.removeItem(at: Self.syncedURL)
            }
        } catch {
            logWarning(.dongle, "Profiles: couldn't keep the synced copy: \(BandLog.describe(error))")
        }
    }

    private static func loadSynced(current: GestureProfileSet) -> Synced? {
        if let hash = UserDefaults.standard.string(forKey: syncedHashKey),
           let data = try? Data(contentsOf: syncedURL), let set = try? GestureProfileSet.decode(data) {
            return Synced(set: set, hash: hash)
        }
        // Older builds kept only the hashes of a set taken from the dongle.
        let copy = UserDefaults.standard.string(forKey: dongleCopyKey)?.split(separator: " ").map(String.init)
        if let copy, copy.count == 2, copy[1] == current.sha8 { return Synced(set: current, hash: copy[0]) }
        return nil
    }

    static var fileURL: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent(fileName)
    }

    init() {
        var loaded = GestureProfileSet.builtin
        if let data = try? Data(contentsOf: Self.fileURL) {
            do {
                loaded = try GestureProfileSet.decode(data)
                logInfo(.dongle, "Profiles: loaded \(Self.fileName) (\(loaded.profiles.count) profiles)")
            } catch {
                logWarning(.dongle, "Profiles: \(Self.fileName) can't be read (\(error)); starting from the built-in set")
            }
        }
        set = loaded
        refresh()
        let synced = Self.loadSynced(current: loaded)
        self.synced = synced
        syncedSha8 = synced?.set.sha8
    }

    private func refresh() {
        validation = set.validate()
        let data = set.minifiedData
        sha8 = ProfileFormat.sha8(data)
        size = data.count
    }

    var isBuiltin: Bool { self.set.sameContent(as: .builtin) }

    // MARK: saving

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    func save() {
        saveTask?.cancel()
        do {
            // Readable in the background too (a profile upload may finish with the phone locked).
            try set.prettyData.write(to: Self.fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            saveError = nil
        } catch {
            saveError = "Couldn't save the profiles: \(error.localizedDescription)"
            logError(.dongle, "Profiles: save failed: \(BandLog.describe(error))")
        }
    }

    // MARK: editing helpers

    func restoreBuiltin() {
        set = .builtin
        logNotice(.dongle, "Profiles: restored the built-in set on the phone")
    }

    func addProfile() -> Int {
        let id = set.unusedID("custom")
        set.profiles.append(GestureProfile(id: id, name: "New profile", buzz: 1, gestures: [ProfileGesture.indexHold.rawValue: .action("menu")],
                                           symbol: GestureProfile.defaultSymbol))
        return set.profiles.count - 1
    }

    func duplicate(_ index: Int) {
        guard set.profiles.indices.contains(index), set.profiles.count < ProfileFormat.maxProfiles else { return }
        let original = set.profiles[index]
        let name = String("\(original.name) copy".prefix(24))
        set.profiles.insert(original.copy(id: set.unusedID(original.id), name: name), at: index + 1)
    }

    /// Removes a profile and whatever pointed at it (menu letters, start entries, `profile:<id>`,
    /// in profiles and everywhere).
    func delete(at offsets: IndexSet) {
        let removed = offsets.map { set.profiles[$0].id }
        var next = set
        next.profiles.remove(atOffsets: offsets)
        for id in removed {
            next.menu = next.menu.filter { $0.value != "profile:\(id)" }
            next.start = next.start.filter { $0.value != id }
            for p in next.profiles.indices {
                for (gesture, binding) in next.profiles[p].gestures {
                    let fixed = Self.dropping("profile:\(id)", from: binding)
                    next.profiles[p].gestures[gesture] = fixed
                }
            }
            for (gesture, binding) in next.everywhere {
                next.everywhere[gesture] = Self.dropping("profile:\(id)", from: binding)
            }
        }
        set = next
    }

    private static func dropping(_ action: String, from binding: GestureBinding) -> GestureBinding? {
        switch binding {
        case .action(let text): text == action ? nil : binding
        case .byHost(let map):
            .make(default: map["default"].flatMap { $0 == action ? nil : $0 }, overrides: map.filter { $0.key != "default" && $0.value != action })
        }
    }

    /// Renames a profile id everywhere it's used.
    func rename(id old: String, to new: String) {
        guard old != new else { return }
        var next = set
        for p in next.profiles.indices where next.profiles[p].id == old { next.profiles[p].id = new }
        next.menu = next.menu.mapValues { $0 == "profile:\(old)" ? "profile:\(new)" : $0 }
        next.start = next.start.mapValues { $0 == old ? new : $0 }
        let renamed = { (binding: GestureBinding) -> GestureBinding in
            switch binding {
            case .action(let text): .action(text == "profile:\(old)" ? "profile:\(new)" : text)
            case .byHost(let map): .byHost(map.mapValues { $0 == "profile:\(old)" ? "profile:\(new)" : $0 })
            }
        }
        for p in next.profiles.indices {
            next.profiles[p].gestures = next.profiles[p].gestures.mapValues(renamed)
        }
        next.everywhere = next.everywhere.mapValues(renamed)
        set = next
    }

    // MARK: changes against the dongle

    /// Puts one part back as `dongle` has it.
    func revert(_ part: ProfileSetPart, to dongle: GestureProfileSet) {
        set = set.replacing(part, from: dongle)
    }

    /// Drops every edit since `dongle`, keeping the app's identities for profiles both have.
    func discardChanges(to dongle: GestureProfileSet) {
        set = set.differences(from: dongle).reduce(set) { $0.replacing($1, from: dongle) }
        logNotice(.dongle, "Profiles: discarded the phone's changes")
    }

    /// Takes a merged set in, `dongle` being the dongle's own when it came from there.
    func applyMerge(_ merged: GestureProfileSet, dongle: (set: GestureProfileSet, hash: String)?) {
        set = merged
        save()
        if let dongle { markSynced(dongle.set, hash: dongle.hash) }
        logNotice(.dongle, "Profiles: merged (\(merged.profiles.count) profiles)")
    }

    // MARK: import

    /// Reads a file or pasted text without applying it.
    static func candidate(_ data: Data, source: String) -> Candidate {
        let error = ProfileFormat.validate(data)
        do {
            let set = try GestureProfileSet.decode(data)
            return Candidate(source: source, set: set, error: error ?? set.validate())
        } catch {
            return Candidate(source: source, set: nil, error: (error as? ProfileError) ?? ProfileError("", error.localizedDescription))
        }
    }

    static func candidate(text: String, source: String) -> Candidate {
        candidate(Data(ProfileFormat.extractJSON(from: text).utf8), source: source)
    }

    /// A file from the importer or another app (Files, AirDrop, Mail).
    static func candidate(url: URL) -> Candidate {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            // A profile file is a few KB; anything huge isn't one.
            if let size = values.fileSize, size > 256 * 1024 {
                return Candidate(source: url.lastPathComponent, set: nil, error: ProfileError("", "\(size) bytes: that's not a profile file"))
            }
            let data = try Data(contentsOf: url)
            return candidate(data, source: url.lastPathComponent)
        } catch {
            return Candidate(source: url.lastPathComponent, set: nil, error: ProfileError("", "Couldn't read the file: \(error.localizedDescription)"))
        }
    }

    func apply(_ candidate: Candidate) {
        guard let imported = candidate.set else { return }
        set = imported
        save()
        if let hash = candidate.dongleHash { markSynced(imported, hash: hash) }
        logNotice(.dongle, "Profiles: imported \(candidate.source) (\(imported.profiles.count) profiles, \(candidate.error == nil ? "valid" : "with problems"))")
    }
}
