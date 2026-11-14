import BandCredentials
import BandLogging
import BandProtocol
import CryptoKit
import Foundation

/// One build Meta offers a band (its update check's answer). Nothing secret: a CDN link, versions,
/// checksum and the id of the key the package needs.
public struct FirmwareOffer: Codable, Sendable, Equatable, Identifiable {
    public var id: String { targetVersion }
    public let targetVersion: String
    public let buildName: String?
    public let baseVersion: String?
    public let releaseTag: String?
    public let releaseNotes: String?
    public let fileURL: URL
    public let fileSize: Int64?
    /// SHA-256 of `ota.zip`, hex.
    public let checksum: String?
    public let kekID: Int64?
    /// Where it came from: host and query.
    public let source: String

    public var title: String { buildName.map { "Build \($0)" } ?? FirmwareLibrary.name(targetVersion) }
}

public struct FirmwareCheckResult: Sendable {
    public let offers: [FirmwareOffer]
    /// What the other hosts and queries answered (no offer, or an error).
    public let notOffered: [String]
}

/// A build downloaded to the phone: `ota.zip` (the same for every band) and, per band, Meta's offer
/// and the key wrapped for that band alone.
public struct FirmwarePackage: Sendable, Equatable, Identifiable {
    public var id: String { version }
    public let version: String
    public let folder: URL
    public let offer: FirmwareOffer?
    public let zipSize: Int64
    /// The key for this band (wrapped by Meta for it) is downloaded.
    public let hasBandKey: Bool
    /// `ota.zip` matches the offer's SHA-256.
    public let checksumMatches: Bool?

    public var title: String { offer?.title ?? FirmwareLibrary.name(version) }
    public var zipURL: URL { folder.appendingPathComponent("ota.zip") }
    public var numericVersion: UInt64? { UInt64(version) }
}

/// What's inside a package, for research.
public struct FirmwareInspection: Sendable {
    public struct File: Sendable, Identifiable {
        public var id: String { path }
        public let path: String
        public let size: Int
        public let compressedSize: Int
        public let method: String
        /// Listed in the manifest as an update item.
        public var item: Item?
        public let sha256: String
        public let md5: String
        /// Shannon entropy in bits per byte: ~8 means encrypted or compressed.
        public let entropy: Double
        public let head: String
        public let guess: String
        public let strings: [String]
    }

    public struct Item: Sendable {
        public let itemType: UInt64
        public let version: UInt64?
        public let declaredSize: Int?
        public let declaredDigest: String?
        public var typeName: String { itemType == 1 ? "firmware" : itemType == 2 ? "ML bundle" : "type \(itemType)" }
    }

    public let files: [File]
    public let manifestText: String?
    /// The manifest's fields other than `items`, readable.
    public let manifestFields: [(key: String, value: String)]
    public let kekVersion: UInt64?
    /// Every item matches the manifest's size and SHA-256.
    public let verified: Bool
    public let problems: [String]
}

public struct FirmwareError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Firmware from Meta for a band without glasses, as Air Gestures for Android does it (its
/// `firmware.rs`, worked out from Meta AI 295.0.0.37.164): the update check is a GraphQL query with
/// the signed-in user's token; the answer has a plain download link; the package is encrypted for
/// the band, and installing it also needs the band's wrapped key, fetched by its id.
/// Files live in Application Support/Firmware (not backed up). The Meta token is never logged.
public enum FirmwareLibrary {
    static let hosts = ["ar-genai.graph.meta.com", "ar.graph.meta.com"]
    static let userAgent = "Dalvik/2.1.0 (Linux; U; Android 14) [FBAN/StellaForAndroid;FBAV/295.0.0.37.164;FBPN/com.facebook.stella;FBLC/en_US;FBSN/Android]"
    /// Meta AI's persisted query ids.
    static let fetchSystemUpdates = "29744781653741296994778085945"
    static let fetchConstellationUpdates = "155904535318377635033579516369"
    static let fetchKek = "313699925716490204858433749875"

    /// Meta's build numbers for the versions seen so far (the Meta AI app shows these).
    static let builds = ["1003366292": "64", "1054928927": "70"]
    /// The newest build the community has tested end to end (gestures, dial, battery, motion, handwriting).
    public static let knownGood: UInt64 = 1_054_928_927

    public static func name(_ version: String) -> String { builds[version].map { "Build \($0)" } ?? version }

    /// The folder for a band's files: a hash of its serial, so the serial isn't in a path.
    public static func bandTag(serial: String) -> String {
        String(SHA256.hash(data: Data("neural-playground band \(serial)".utf8)).map { String(format: "%02x", $0) }.joined().prefix(16))
    }

    public static func root() throws -> URL {
        var url = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Firmware", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        return url
    }

    // MARK: check

    /// Asks Meta which builds it offers this band, every way Meta AI does (they can differ).
    /// `version` "1" asks for a full build.
    public static func check(session: MetaSession, serial: String, version: String = "1") async throws -> FirmwareCheckResult {
        var offers: [FirmwareOffer] = []
        var notOffered: [String] = []
        logNotice(.meta, "Firmware: asking Meta which builds it offers band \(BandLog.mask(serial))")
        for host in hosts {
            let legacy: [String: Any] = ["fetch_request": ["topology_fetch_update_info": [[
                "custom_ota_fetch_type": "CERES_USER_INSIGHTS_NO_DEVICE_IDENTITY",
                "full_update_only": true,
                "device_serial_number": serial,
                "device_type": "ota.ceres_p1.user",
                "fw_version": version,
            ]]]]
            let unified: [String: Any] = ["fetch_request": ["constellation_updates_request_info": [[
                "device_type": "ota.ceres.user",
                "device_serial": serial,
                "device_ota_session_id": UUID().uuidString.lowercased(),
                "device_firmware_version": version,
                "device_feature_list": [Any](),
                "device_artifact_list": [Any](),
                "device_firmware_full_update_only": true,
                "device_firmware_rollout_token": NSNull(),
                "device_manage_mode": NSNull(),
                "constellation_device_type": NSNull(),
                "constellation_device_firmware_version": NSNull(),
                "constellation_device_serial": NSNull(),
                "supports_firmware_manifest_v1": true,
            ]]]]
            for (name, id, variables) in [("FetchSystemUpdates", fetchSystemUpdates, legacy), ("FetchConstellationUpdates", fetchConstellationUpdates, unified)] {
                do {
                    let json = try await graphql(session: session, host: host, name: name, id: id, variables: variables)
                    if let raw = findOffer(json), let offer = offer(raw, source: "\(host) \(name)") {
                        logNotice(.meta, "Firmware: \(host) \(name) offers \(offer.targetVersion) (\(offer.title))")
                        if !offers.contains(where: { $0.targetVersion == offer.targetVersion }) { offers.append(offer) }
                    } else if let errors = errors(json) {
                        notOffered.append("\(host) \(name): \(errors)")
                    } else {
                        notOffered.append("\(host) \(name): no update offered")
                    }
                } catch {
                    notOffered.append("\(host) \(name): \(error.localizedDescription)")
                }
            }
        }
        for line in notOffered { logInfo(.meta, "Firmware: \(line)") }
        return FirmwareCheckResult(offers: offers, notOffered: notOffered)
    }

    static func graphql(session: MetaSession, host: String, name: String, id: String, variables: [String: Any]) async throws -> [String: Any] {
        let variablesText = String(decoding: try JSONSerialization.data(withJSONObject: variables), as: UTF8.self)
        var request = URLRequest(url: URL(string: "https://\(host)/graphql")!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("OAuth \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(name, forHTTPHeaderField: "X-FB-Friendly-Name")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = MetaAuth.urlForm([
            ("method", "post"), ("pretty", "false"), ("format", "json"), ("server_timestamps", "true"), ("locale", "en_US"),
            ("purpose", "fetch"), ("fb_api_req_friendly_name", name), ("client_doc_id", id), ("variables", variablesText),
        ])
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw FirmwareError("couldn't reach Meta (\(error.localizedDescription))")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        var text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("for (;;);") { text.removeFirst("for (;;);".count) }
        guard let json = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else {
            throw FirmwareError("Meta answered HTTP \(status), not JSON")
        }
        logInfo(.meta, "Firmware: \(host) \(name): HTTP \(status), \(data.count)B")
        if status != 200 {
            throw FirmwareError("Meta answered HTTP \(status): \(errors(json) ?? "no message")\(status == 401 || status == 400 ? " (sign in to Meta again)" : "")")
        }
        return json
    }

    /// Meta's error messages, nothing else from the response.
    static func errors(_ json: [String: Any]) -> String? {
        var messages: [String] = []
        for error in (json["errors"] as? [[String: Any]] ?? []) + [json["error"] as? [String: Any]].compactMap({ $0 }) {
            if let message = (error["message"] as? String) ?? (error["summary"] as? String) { messages.append(message) }
        }
        return messages.isEmpty ? nil : messages.joined(separator: "; ")
    }

    /// The offer in a response, legacy or unified: the object with `file_uri`.
    static func findOffer(_ value: Any) -> [String: Any]? {
        if let map = value as? [String: Any] {
            if map["file_uri"] != nil { return map }
            for child in map.values { if let found = findOffer(child) { return found } }
        } else if let list = value as? [Any] {
            for child in list { if let found = findOffer(child) { return found } }
        }
        return nil
    }

    static func text(_ value: Any?) -> String? {
        switch value {
        case let string as String: string.isEmpty ? nil : string
        case let number as NSNumber: number.stringValue
        default: nil
        }
    }

    static func offer(_ raw: [String: Any], source: String) -> FirmwareOffer? {
        guard let link = text(raw["file_uri"]), let url = URL(string: link), url.scheme == "https" else { return nil }
        var notes = text(raw["release_notes_cms"]) ?? text(raw["release_notes"])
        notes = notes?.replacingOccurrences(of: "<if-param-isnt-set.*?</if-param-isnt-set>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return FirmwareOffer(targetVersion: text(raw["target_version"]) ?? "unknown", buildName: text(raw["build_number_display_name"]),
                             baseVersion: text(raw["base_version"]), releaseTag: text(raw["release_tag"]),
                             releaseNotes: notes?.isEmpty == false ? notes : nil, fileURL: url,
                             fileSize: text(raw["file_size"]).flatMap { Int64($0) }, checksum: text(raw["file_checksum"])?.lowercased(),
                             kekID: text(raw["kek_id"]).flatMap { Int64($0) }, source: source)
    }

    // MARK: download

    /// Downloads an offer's package (unless already here with the right checksum) and, when the offer
    /// names one, the band's wrapped key.
    public static func download(_ offer: FirmwareOffer, session: MetaSession, serial: String,
                                progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> FirmwarePackage {
        guard offer.targetVersion.allSatisfy(\.isNumber) else { throw FirmwareError("odd version \(offer.targetVersion)") }
        let folder = try root().appendingPathComponent(offer.targetVersion, isDirectory: true)
        let band = folder.appendingPathComponent("bands/\(bandTag(serial: serial))", isDirectory: true)
        try FileManager.default.createDirectory(at: band, withIntermediateDirectories: true)
        try JSONEncoder.pretty.encode(offer).write(to: band.appendingPathComponent("offer.json"), options: .atomic)
        let zip = folder.appendingPathComponent("ota.zip")
        if let checksum = offer.checksum, let existing = try? Data(contentsOf: zip), sha256(existing) == checksum {
            logInfo(.meta, "Firmware: \(offer.targetVersion) already downloaded")
        } else {
            try await fetch(offer.fileURL, to: zip, expected: offer.fileSize ?? 0, progress: progress)
        }
        if let kekID = offer.kekID {
            let host = offer.source.split(separator: " ").first.map(String.init) ?? hosts[0]
            let json = try await graphql(session: session, host: host, name: "FetchEncryptedKEKInfoByKEKId", id: fetchKek,
                                         variables: ["request": ["device_serial_number": serial, "kek_id": kekID]])
            if let errors = errors(json) { throw FirmwareError("Meta didn't give the band's key: \(errors)") }
            let file = band.appendingPathComponent("kek.json")
            try JSONSerialization.data(withJSONObject: json).write(to: file, options: [.atomic, .completeFileProtection])
            logNotice(.meta, "Firmware: key \(kekID) for this band saved (wrapped by Meta for the band; never shown or exported)")
        }
        return package(folder: folder, bandTag: bandTag(serial: serial))!
    }

    static func fetch(_ url: URL, to destination: URL, expected: Int64, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        let (bytes, response) = try await URLSession.shared.bytes(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw FirmwareError("download failed: HTTP \(status)") }
        let total = response.expectedContentLength > 0 ? response.expectedContentLength : expected
        let partial = destination.appendingPathExtension("part")
        FileManager.default.createFile(atPath: partial.path, contents: nil)
        let handle = try FileHandle(forWritingTo: partial)
        var buffer = Data()
        buffer.reserveCapacity(1 << 18)
        var written: Int64 = 0
        do {
            for try await byte in bytes {
                buffer.append(byte)
                if buffer.count >= 1 << 18 {
                    try handle.write(contentsOf: buffer)
                    written += Int64(buffer.count)
                    buffer.removeAll(keepingCapacity: true)
                    progress(written, total)
                }
            }
            try handle.write(contentsOf: buffer)
            written += Int64(buffer.count)
            try handle.close()
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: partial)
            throw FirmwareError("download failed: \(error.localizedDescription)")
        }
        progress(written, total)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: partial, to: destination)
        logNotice(.meta, "Firmware: downloaded \(written) bytes")
    }

    // MARK: library

    /// Every downloaded build, newest first, read for this band.
    public static func packages(bandTag: String?) -> [FirmwarePackage] {
        guard let root = try? root(), let folders = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        return folders.filter { $0.lastPathComponent.allSatisfy(\.isNumber) }
            .compactMap { package(folder: $0, bandTag: bandTag) }
            .sorted { ($0.numericVersion ?? 0) > ($1.numericVersion ?? 0) }
    }

    static func package(folder: URL, bandTag: String?) -> FirmwarePackage? {
        let zip = folder.appendingPathComponent("ota.zip")
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: zip.path) else { return nil }
        let bands = folder.appendingPathComponent("bands")
        let mine = bandTag.map { bands.appendingPathComponent($0) }
        let offerFile = [mine].compactMap { $0 }.map { $0.appendingPathComponent("offer.json") }.first { FileManager.default.fileExists(atPath: $0.path) }
            ?? (try? FileManager.default.contentsOfDirectory(at: bands, includingPropertiesForKeys: nil))?
            .map { $0.appendingPathComponent("offer.json") }.first { FileManager.default.fileExists(atPath: $0.path) }
        let offer = offerFile.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode(FirmwareOffer.self, from: $0) }
        let hasKey = mine.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent("kek.json").path) } ?? false
        let checksum = offer?.checksum.map { expected in (try? Data(contentsOf: zip)).map { sha256($0) == expected } ?? false }
        return FirmwarePackage(version: folder.lastPathComponent, folder: folder, offer: offer,
                               zipSize: (attributes[.size] as? NSNumber)?.int64Value ?? 0, hasBandKey: hasKey, checksumMatches: checksum)
    }

    public static func delete(_ package: FirmwarePackage) throws {
        try FileManager.default.removeItem(at: package.folder)
        logInfo(.meta, "Firmware: deleted \(package.version)")
    }

    /// Files to share for research: the package and Meta's offer. Never the band's key.
    public static func exportFiles(_ package: FirmwarePackage) -> [URL] {
        var files = [package.zipURL]
        if let offer = package.offer, let data = try? JSONEncoder.pretty.encode(offer) {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("firmware-\(package.version)-offer.json")
            if (try? data.write(to: url)) != nil { files.append(url) }
        }
        return files
    }

    // MARK: inspection

    public static func inspect(_ package: FirmwarePackage) throws -> FirmwareInspection {
        let zip = try ZipReader(data: Data(contentsOf: package.zipURL))
        var problems: [String] = []
        var manifestText: String?
        var manifestFields: [(String, String)] = []
        var itemsByPath: [String: FirmwareInspection.Item] = [:]
        var kekVersion: UInt64?
        if let entry = zip.entry("manifest.json") {
            let data = try zip.read(entry)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                manifestText = (try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])).map { String(decoding: $0, as: UTF8.self) }
                for key in json.keys.sorted() where key != "items" {
                    manifestFields.append((key, describe(json[key])))
                }
                kekVersion = (json["kek_version"] as? NSNumber)?.uint64Value
                for item in json["items"] as? [[String: Any]] ?? [] {
                    guard let path = item["path"] as? String else { problems.append("manifest item without a path"); continue }
                    itemsByPath[path] = .init(itemType: (item["item_type"] as? NSNumber)?.uint64Value ?? 0,
                                              version: (item["version"] as? NSNumber)?.uint64Value,
                                              declaredSize: (item["size"] as? NSNumber)?.intValue,
                                              declaredDigest: (item["digest"] as? String)?.lowercased())
                }
            } else {
                manifestText = String(decoding: data, as: UTF8.self)
                problems.append("manifest.json isn't a JSON object")
            }
        } else {
            problems.append("no manifest.json")
        }
        var files: [FirmwareInspection.File] = []
        var verified = !itemsByPath.isEmpty
        for entry in zip.entries where !entry.name.hasSuffix("/") {
            let data: Data
            do { data = try zip.read(entry) } catch {
                problems.append(error.localizedDescription)
                verified = false
                continue
            }
            let item = itemsByPath[entry.name]
            let digest = sha256(data)
            if let item {
                if let size = item.declaredSize, size != data.count { problems.append("\(entry.name): \(data.count) bytes, manifest says \(size)"); verified = false }
                if let declared = item.declaredDigest, declared != digest { problems.append("\(entry.name): SHA-256 doesn't match the manifest"); verified = false }
            }
            files.append(.init(path: entry.name, size: data.count, compressedSize: entry.compressedSize, method: entry.methodName, item: item,
                               sha256: digest, md5: Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                               entropy: entropy(data), head: data.prefix(32).map { String(format: "%02x", $0) }.joined(separator: " "),
                               guess: guess(data), strings: strings(data)))
        }
        for path in itemsByPath.keys where !files.contains(where: { $0.path == path }) {
            problems.append("the package lacks \(path)")
            verified = false
        }
        return FirmwareInspection(files: files, manifestText: manifestText, manifestFields: manifestFields, kekVersion: kekVersion,
                                  verified: verified && problems.isEmpty, problems: problems)
    }

    static func describe(_ value: Any?) -> String {
        guard let value else { return "null" }
        if let text = text(value) { return text }
        if JSONSerialization.isValidJSONObject(value), let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) {
            return String(decoding: data, as: UTF8.self)
        }
        return "\(value)"
    }

    static func entropy(_ data: Data) -> Double {
        guard !data.isEmpty else { return 0 }
        var counts = [Int](repeating: 0, count: 256)
        for byte in data { counts[Int(byte)] += 1 }
        let total = Double(data.count)
        return counts.reduce(0.0) { sum, count in
            guard count > 0 else { return sum }
            let p = Double(count) / total
            return sum - p * log2(p)
        }
    }

    static func guess(_ data: Data) -> String {
        let head = [UInt8](data.prefix(8))
        if head.starts(with: [0x7f, 0x45, 0x4c, 0x46]) { return "ELF executable" }
        if head.starts(with: [0x50, 0x4b, 0x03, 0x04]) { return "ZIP archive" }
        if head.starts(with: [0x1f, 0x8b]) { return "gzip" }
        if head.starts(with: [0x28, 0xb5, 0x2f, 0xfd]) { return "zstd" }
        if head.first == UInt8(ascii: "{") { return "JSON / text" }
        let bits = entropy(data)
        if bits > 7.95 { return "encrypted (or compressed): no structure visible" }
        if bits > 7.5 { return "compressed or mostly encrypted" }
        return "binary with structure (\(String(format: "%.1f", bits)) bits/byte)"
    }

    /// Printable ASCII runs of 6+ characters, at most 60.
    static func strings(_ data: Data) -> [String] {
        var found: [String] = []
        var run: [UInt8] = []
        for byte in data {
            if byte >= 0x20 && byte < 0x7f {
                run.append(byte)
            } else {
                if run.count >= 6 { found.append(String(decoding: run, as: UTF8.self)) }
                run = []
                if found.count >= 60 { break }
            }
        }
        if run.count >= 6, found.count < 60 { found.append(String(decoding: run, as: UTF8.self)) }
        return found
    }

    static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    // MARK: install plan

    /// The package as an update for this band: each item checked against the manifest, and the
    /// band's own key (never another band's: the band refuses it).
    public static func plan(_ package: FirmwarePackage, bandTag: String, mode: OtaMode) throws -> OtaPlan {
        let zip = try ZipReader(data: Data(contentsOf: package.zipURL))
        guard let entry = zip.entry("manifest.json"),
              let manifest = try JSONSerialization.jsonObject(with: zip.read(entry)) as? [String: Any],
              let items = manifest["items"] as? [[String: Any]] else { throw FirmwareError("the package has no usable manifest") }
        var version: UInt64?
        var firmware: (data: [UInt8], md5: [UInt8])?
        var model: (data: [UInt8], md5: [UInt8])?
        for item in items {
            guard let path = item["path"] as? String, !path.contains(".."), !path.hasPrefix("/") else { throw FirmwareError("manifest: odd item path") }
            guard let file = zip.entry(path) else { throw FirmwareError("the package lacks \(path)") }
            let data = try zip.read(file)
            guard (item["size"] as? NSNumber)?.intValue == data.count else { throw FirmwareError("\(path): size doesn't match the manifest") }
            guard (item["digest"] as? String)?.lowercased() == sha256(data) else { throw FirmwareError("\(path): SHA-256 doesn't match the manifest") }
            guard let this = (item["version"] as? NSNumber)?.uint64Value else { throw FirmwareError("manifest: item without a version") }
            if let version, version != this { throw FirmwareError("manifest: the items have different versions") }
            version = this
            let entry = ([UInt8](data), Array(Insecure.MD5.hash(data: data)))
            switch (item["item_type"] as? NSNumber)?.intValue {
            case 1: firmware = entry
            case 2: model = entry
            case let other: throw FirmwareError("\(path): unknown item type \(other.map(String.init) ?? "none")")
            }
        }
        guard let firmware else { throw FirmwareError("manifest: no firmware item") }
        guard let version else { throw FirmwareError("manifest: no version") }
        guard let kekVersion = (manifest["kek_version"] as? NSNumber)?.uint64Value else { throw FirmwareError("manifest: no kek_version") }
        var kek: (id: UInt64, key: [UInt8])?
        let keyFile = package.folder.appendingPathComponent("bands/\(bandTag)/kek.json")
        if let data = try? Data(contentsOf: keyFile) {
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let info = (json["data"] as? [String: Any])?["xar_fetch_encrypted_kek_info_by_kek_id"] as? [String: Any] else {
                throw FirmwareError("the band's key file is damaged; check with Meta again")
            }
            guard info["encryption_algo"] as? String == "AES_128" else { throw FirmwareError("the band's key uses an unexpected algorithm") }
            guard let encoded = info["encrypted_kek"] as? String, let key = Data(base64Encoded: encoded) else { throw FirmwareError("the band's key file has no key") }
            kek = (kekVersion, [UInt8](key))
        }
        return OtaPlan(version: version, firmware: firmware.data, firmwareMD5: firmware.md5, model: model, kek: kek, mode: mode)
    }
}

extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

/// An install the app committed, followed across the band's restart. Persisted (not secret).
public struct FirmwareInstall: Codable, Sendable, Equatable {
    public enum Stage: String, Codable, Sendable { case restarting, checking, installed, failed }
    public var version: UInt64
    public var stage: Stage
    public var since: Date
    /// What the band reported running after it came back.
    public var running: UInt64?

    static let key = "firmware.install"
    static func load() -> FirmwareInstall? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(FirmwareInstall.self, from: $0) }
    }
    func save() { UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: Self.key) }
    static func clear() { UserDefaults.standard.removeObject(forKey: key) }
}
