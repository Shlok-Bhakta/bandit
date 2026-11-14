import CryptoKit
import Foundation
import Testing
@testable import BandKit
@testable import BandProtocol

/// A package shaped like Meta's (`manifest.json` plus items), zipped with the system `zip` (deflate).
@Suite struct FirmwarePackageTests {
    let firmware = Data((0..<40_000).map { UInt8(truncatingIfNeeded: ($0 * 31) ^ ($0 >> 3)) })
    let model = Data(repeating: 0x5a, count: 20_000)

    func hex(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    func makePackage(tamper: Bool = false, key: Bool = true) throws -> (FirmwarePackage, String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fw-\(UUID().uuidString)")
        let source = root.appendingPathComponent("src")
        let folder = root.appendingPathComponent("1054928927")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try (tamper ? firmware + Data([1]) : firmware).write(to: source.appendingPathComponent("fw.bin"))
        try model.write(to: source.appendingPathComponent("ml.bin"))
        let manifest: [String: Any] = [
            "kek_version": 20, "format": 1,
            "items": [
                ["path": "fw.bin", "item_type": 1, "version": 1_054_928_927, "size": firmware.count, "digest": hex(firmware)],
                ["path": "ml.bin", "item_type": 2, "version": 1_054_928_927, "size": model.count, "digest": hex(model)],
            ],
        ]
        try JSONSerialization.data(withJSONObject: manifest).write(to: source.appendingPathComponent("manifest.json"))
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = source
        zip.arguments = ["-q", "-9", folder.appendingPathComponent("ota.zip").path, "manifest.json", "fw.bin", "ml.bin"]
        try zip.run()
        zip.waitUntilExit()
        let tag = FirmwareLibrary.bandTag(serial: "SIMBAND0001")
        let band = folder.appendingPathComponent("bands/\(tag)")
        try FileManager.default.createDirectory(at: band, withIntermediateDirectories: true)
        if key {
            let kek: [String: Any] = ["data": ["xar_fetch_encrypted_kek_info_by_kek_id": ["encryption_algo": "AES_128", "encrypted_kek": Data(repeating: 7, count: 40).base64EncodedString()]]]
            try JSONSerialization.data(withJSONObject: kek).write(to: band.appendingPathComponent("kek.json"))
        }
        return (FirmwareLibrary.package(folder: folder, bandTag: tag)!, tag)
    }

    @Test func aPackageIsInspectedAndBecomesAPlan() throws {
        let (package, tag) = try makePackage()
        #expect(package.title == "Build 70")
        #expect(package.hasBandKey)
        let inspection = try FirmwareLibrary.inspect(package)
        #expect(inspection.verified, "\(inspection.problems)")
        #expect(inspection.kekVersion == 20)
        #expect(inspection.files.count == 3)
        #expect(inspection.files.first { $0.path == "ml.bin" }?.entropy == 0)
        #expect(inspection.files.first { $0.path == "fw.bin" }?.item?.typeName == "firmware")
        #expect(inspection.manifestFields.contains { $0.key == "format" && $0.value == "1" })
        let plan = try FirmwareLibrary.plan(package, bandTag: tag, mode: .trial)
        #expect(plan.version == 1_054_928_927)
        #expect(plan.firmware == [UInt8](firmware))
        #expect(plan.firmwareMD5 == Array(Insecure.MD5.hash(data: firmware)))
        #expect(plan.model?.data == [UInt8](model))
        #expect(plan.kek?.id == 20 && plan.kek?.key == [UInt8](repeating: 7, count: 40))
        #expect(!FirmwareLibrary.exportFiles(package).contains { $0.lastPathComponent == "kek.json" }, "the band's key is never exported")
    }

    @Test func aTamperedItemIsCaughtBeforeAnythingIsSent() throws {
        let (package, tag) = try makePackage(tamper: true)
        let inspection = try FirmwareLibrary.inspect(package)
        #expect(!inspection.verified)
        #expect(throws: FirmwareError.self) { try FirmwareLibrary.plan(package, bandTag: tag, mode: .update) }
    }

    @Test func withoutTheBandsKeyThePlanCarriesNone() throws {
        let (package, tag) = try makePackage(key: false)
        #expect(!package.hasBandKey)
        #expect(try FirmwareLibrary.plan(package, bandTag: tag, mode: .send).kek == nil)
    }

    @Test func offersAreFoundInEitherResponseShape() {
        let legacy: [String: Any] = ["data": ["x": ["fetch_update_info_list": [["fetch_update_response": ["file_uri": "https://x/ota.zip", "target_version": "123", "kek_id": 20, "file_checksum": "AB"]]]]]]
        let offer = FirmwareLibrary.findOffer(legacy).flatMap { FirmwareLibrary.offer($0, source: "h q") }
        #expect(offer?.targetVersion == "123" && offer?.kekID == 20 && offer?.checksum == "ab")
        let unified: [String: Any] = ["data": ["y": ["constellation_updates_response_info": [["firmware_update_info": ["file_uri": "https://u/z", "target_version": 9]]]]]]
        #expect(FirmwareLibrary.findOffer(unified).flatMap { FirmwareLibrary.offer($0, source: "") }?.targetVersion == "9")
        #expect(FirmwareLibrary.findOffer(["data": ["x": []]]) == nil)
        #expect(FirmwareLibrary.offer(["file_uri": "http://insecure/z"], source: "") == nil, "only https links")
    }
}
