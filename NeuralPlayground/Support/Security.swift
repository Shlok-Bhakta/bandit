import BandLogging
import Foundation
import LocalAuthentication
import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum DeviceAuth {
    /// Face ID / Touch ID, falling back to the device passcode.
    static func authenticate(_ reason: String) async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            logWarning(.credentials, "Device authentication unavailable: \(error.map { BandLog.describe($0) } ?? "unknown")")
            return false
        }
        do {
            let ok = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            logInfo(.credentials, "Device authentication \(ok ? "succeeded" : "failed") for: \(reason)")
            return ok
        } catch {
            logInfo(.credentials, "Device authentication cancelled or failed: \(BandLog.describe(error))")
            return false
        }
    }
}

enum SecureClipboard {
    /// Local-only (no Universal Clipboard) and expiring after `seconds`.
    static func copySecret(_ text: String, seconds: TimeInterval = 60) {
        UIPasteboard.general.setItems([[UTType.plainText.identifier: text]],
                                      options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(seconds)])
        logNotice(.credentials, "Owner key copied to the clipboard (local only, expires in \(Int(seconds)) s)")
    }

    static func copy(_ text: String) {
        UIPasteboard.general.string = text
    }
}

extension UTType {
    static let encryptedBandBackup = UTType(exportedAs: "dev.neuralplayground.encrypted-backup", conformingTo: .json)
}

/// A file for `.fileExporter`.
struct DataDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json, .encryptedBandBackup, .commaSeparatedText, .plainText] }
    var data: Data

    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// Writes a temporary, file-protected copy for the share sheet and removes it afterwards.
enum TemporaryShareFile {
    static func make(name: String, data: Data) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("share-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }

    static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}

/// UIActivityViewController wrapper that deletes the shared temporary file when the sheet closes.
struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    var onComplete: (Bool) -> Void = { _ in }

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        controller.completionWithItemsHandler = { activity, completed, _, _ in
            logInfo(.credentials, "Share sheet closed (\(completed ? "shared via \(activity?.rawValue ?? "?")" : "cancelled"))")
            if url.path.hasPrefix(FileManager.default.temporaryDirectory.path) { TemporaryShareFile.remove(url) }
            onComplete(completed)
        }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

struct SharedFile: Identifiable {
    let id = UUID()
    let url: URL
}
