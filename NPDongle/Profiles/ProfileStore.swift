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

    /// The phone's set as taken from the dongle: (the dongle's hash, the phone's), so the two count
    /// as the same set until either changes.
    private(set) var dongleCopy: (dongle: String, phone: String)? {
        didSet {
            UserDefaults.standard.set(dongleCopy.map { "\($0.dongle) \($0.phone)" }, forKey: Self.dongleCopyKey)
        }
    }
    private static let dongleCopyKey = "profiles.dongleCopy"

    /// Whether the dongle's set (status `ph`) is this phone's.
    func isOnDongle(_ hash: String) -> Bool {
        hash == sha8 || (hash == ProfileFormat.builtinHash && isBuiltin) || (dongleCopy?.dongle == hash && dongleCopy?.phone == sha8)
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
        let copy = UserDefaults.standard.string(forKey: Self.dongleCopyKey)?.split(separator: " ").map(String.init)
        if let copy, copy.count == 2 { dongleCopy = (copy[0], copy[1]) }
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

    /// Removes a profile and whatever pointed at it (menu letters, start entries, `profile:<id>`).
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
        for p in next.profiles.indices {
            next.profiles[p].gestures = next.profiles[p].gestures.mapValues { binding in
                switch binding {
                case .action(let text): .action(text == "profile:\(old)" ? "profile:\(new)" : text)
                case .byHost(let map): .byHost(map.mapValues { $0 == "profile:\(old)" ? "profile:\(new)" : $0 })
                }
            }
        }
        set = next
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
        dongleCopy = candidate.dongleHash.map { ($0, sha8) }
        logNotice(.dongle, "Profiles: imported \(candidate.source) (\(imported.profiles.count) profiles, \(candidate.error == nil ? "valid" : "with problems"))")
    }
}
