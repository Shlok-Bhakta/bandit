import BandLogging
import CoreTransferable
import DongleProtocol
import Foundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

extension UTType {
    /// `.npprofiles`: an np-profiles JSON file (Info.plist exports it).
    static let npProfiles = UTType(exportedAs: ProfileFormat.typeIdentifier, conformingTo: .json)
}

enum Clipboard {
    static func copy(_ text: String) {
        UIPasteboard.general.string = text
    }

    static var text: String? { UIPasteboard.general.string }
}

/// A profile set as a `.npprofiles` file for ShareLink (pretty-printed, named after the set).
struct ProfilesFile: Transferable {
    let data: Data
    let name: String

    var fileName: String {
        let safe = name.components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_")).inverted).joined()
            .trimmingCharacters(in: .whitespaces)
        return "\(safe.isEmpty ? "profiles" : safe).\(ProfileFormat.fileExtension)"
    }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .npProfiles) { file in
            SentTransferredFile(try TemporaryShareFile.make(name: file.fileName, data: file.data))
        }
    }
}

/// Writes a temporary, file-protected copy for the share sheet.
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

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        controller.completionWithItemsHandler = { activity, completed, _, _ in
            logInfo(.dongle, "Share sheet closed (\(completed ? "shared via \(activity?.rawValue ?? "?")" : "cancelled"))")
            if url.path.hasPrefix(FileManager.default.temporaryDirectory.path) { TemporaryShareFile.remove(url) }
        }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

struct SharedFile: Identifiable {
    let id = UUID()
    let url: URL
}
