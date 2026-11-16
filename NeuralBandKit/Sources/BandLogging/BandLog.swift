import Foundation
import OSLog

/// The shared, copy-paste-friendly log for every layer of the band stack.
///
/// Rules for callers (enforced by review, not by type): never pass owner keys, Meta tokens,
/// receipts, certificates or decrypted payloads. Log sizes, type words, channels, result codes
/// and stage names instead. `BandLog.mask(_:)` shortens identifiers such as serial numbers.
///
/// Entries go to three places: an in-memory ring buffer (the in-app Logs screen), a per-launch
/// file under Application Support/Logs (survives crashes; the last 5 launches are kept), and
/// `os.Logger` (Console.app, subsystem `io.github.shlok-bhakta.bandit`).
public final class BandLog: @unchecked Sendable {
    public enum Level: Int, Sendable, Comparable, CaseIterable, Codable {
        case debug, info, notice, warning, error

        public static func < (lhs: Level, rhs: Level) -> Bool { lhs.rawValue < rhs.rawValue }

        public var tag: String {
            switch self {
            case .debug: "DEBUG"
            case .info: "INFO "
            case .notice: "NOTE "
            case .warning: "WARN "
            case .error: "ERROR"
            }
        }
    }

    public enum Category: String, Sendable, CaseIterable, Codable {
        case app, bluetooth, l2cap, session, crypto, ownership, meta, credentials, gestures, haptics, emg, games, dongle
    }

    public struct Entry: Sendable, Identifiable, Codable {
        public let id: Int
        public let date: Date
        /// Seconds since this launch (monotonic), for precise timing comparisons.
        public let uptime: Double
        public let level: Level
        public let category: Category
        public let message: String

        public var line: String {
            "\(BandLog.timeFormatter.string(from: date)) +\(String(format: "%9.3f", uptime)) \(level.tag) [\(category.rawValue)] \(message)"
        }
    }

    public static let shared = BandLog()

    static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    private let lock = NSLock()
    private var entries: [Entry] = []
    private var nextID = 0
    private let capacity = 20_000
    private let start = ProcessInfo.processInfo.systemUptime
    private var loggers: [Category: Logger] = [:]
    private var file: FileHandle?
    private let fileQueue = DispatchQueue(label: "io.github.shlok-bhakta.bandit.log.file")
    private var verboseFrames = false
    private var echo = false
    private var revisionCounter = 0
    /// Bumped on every append; UI can poll it cheaply.
    public var revision: Int { lock.withLock { revisionCounter } }
    public let launchFile: URL?

    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Logs", isDirectory: true)
        var launchFile: URL?
        if let base {
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            Self.prune(base, keep: 4)
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let url = base.appendingPathComponent("band-\(stamp).log")
            if FileManager.default.createFile(atPath: url.path, contents: nil) {
                file = try? FileHandle(forWritingTo: url)
                launchFile = url
            }
        }
        self.launchFile = launchFile
        for category in Category.allCases {
            loggers[category] = Logger(subsystem: "io.github.shlok-bhakta.bandit", category: category.rawValue)
        }
    }

    private static func prune(_ directory: URL, keep: Int) {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey]))?
            .filter { $0.pathExtension == "log" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent } ?? []
        for old in files.dropFirst(keep) { try? FileManager.default.removeItem(at: old) }
    }

    /// Log every DataX frame header (channel, type words, size) while streaming. Off by default:
    /// motion arrives at ~100 Hz.
    public var logsFrames: Bool {
        get { lock.withLock { verboseFrames } }
        set { lock.withLock { verboseFrames = newValue } }
    }

    /// Also print each entry to standard output (command-line tools).
    public var echoesToStandardOutput: Bool {
        get { lock.withLock { echo } }
        set { lock.withLock { echo = newValue } }
    }

    public func log(_ level: Level, _ category: Category, _ message: @autoclosure () -> String) {
        let text = message()
        let entry: Entry = lock.withLock {
            let entry = Entry(id: nextID, date: Date(), uptime: ProcessInfo.processInfo.systemUptime - start,
                              level: level, category: category, message: text)
            nextID += 1
            entries.append(entry)
            if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
            revisionCounter &+= 1
            return entry
        }
        if echoesToStandardOutput { FileHandle.standardOutput.write(Data((entry.line + "\n").utf8)) }
        let logger = loggers[category]
        switch level {
        case .debug: logger?.debug("\(text, privacy: .public)")
        case .info: logger?.info("\(text, privacy: .public)")
        case .notice: logger?.notice("\(text, privacy: .public)")
        case .warning: logger?.warning("\(text, privacy: .public)")
        case .error: logger?.error("\(text, privacy: .public)")
        }
        if let file {
            let line = Data((entry.line + "\n").utf8)
            fileQueue.async { try? file.write(contentsOf: line) }
        }
    }

    public func snapshot() -> [Entry] { lock.withLock { entries } }

    public func clear() {
        lock.withLock {
            entries.removeAll()
            revisionCounter &+= 1
        }
        log(.notice, .app, "Log cleared by user")
    }

    /// Plain text, one entry per line, with a header describing the device and app.
    public func export(minimumLevel: Level = .debug, categories: Set<Category>? = nil, header: String = "") -> String {
        let lines = snapshot()
            .filter { $0.level >= minimumLevel && (categories?.contains($0.category) ?? true) }
            .map(\.line)
        return (header.isEmpty ? "" : header + "\n") + lines.joined(separator: "\n") + "\n"
    }

    /// Shortens an identifier for logs: `ABCD…WXYZ (16)`.
    public static func mask(_ value: String, keep: Int = 3) -> String {
        guard value.count > keep * 2 else { return String(repeating: "•", count: value.count) }
        return "\(value.prefix(keep))…\(value.suffix(keep)) (\(value.count))"
    }

    /// `NSError` domain/code plus description: what's needed to diagnose a CoreBluetooth failure.
    public static func describe(_ error: Error) -> String {
        let native = error as NSError
        return "\(native.domain) \(native.code): \(error.localizedDescription)"
    }
}

/// Convenience free functions so call sites stay short.
@inline(__always) public func logDebug(_ category: BandLog.Category, _ message: @autoclosure () -> String) {
    BandLog.shared.log(.debug, category, message())
}
@inline(__always) public func logInfo(_ category: BandLog.Category, _ message: @autoclosure () -> String) {
    BandLog.shared.log(.info, category, message())
}
@inline(__always) public func logNotice(_ category: BandLog.Category, _ message: @autoclosure () -> String) {
    BandLog.shared.log(.notice, category, message())
}
@inline(__always) public func logWarning(_ category: BandLog.Category, _ message: @autoclosure () -> String) {
    BandLog.shared.log(.warning, category, message())
}
@inline(__always) public func logError(_ category: BandLog.Category, _ message: @autoclosure () -> String) {
    BandLog.shared.log(.error, category, message())
}
