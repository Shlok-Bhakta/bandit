import CryptoKit
import Foundation
import Testing
@testable import DongleProtocol

@Suite struct DongleStatusTests {
    @Test func decodesTheDocumentedExample() throws {
        let json = """
        {"fw":"0.6.0","id":"3fa2c1d0","slot":"ota_0","verify":false,"up":123,"heap":81234,
         "band":{"s":"live","bat":80,"chg":false,"hand":"right"},
         "mode":"media","pair":0,"you":1,
         "hosts":[{"h":1,"k":"phone","n":"iPhone","act":true},{"h":2,"k":"computer","n":"Work Mac","act":false}],
         "upd":{"s":"idle","got":0,"of":0,"e":""}}
        """
        let status = try DongleStatus.decode(Data(json.utf8))
        #expect(status.firmware == "0.6.0")
        #expect(status.buildID == "3fa2c1d0")
        #expect(status.slot == "ota_0")
        #expect(!status.onProbation)
        #expect(status.uptime == 123)
        #expect(status.band == DongleStatus.Band(state: "live", battery: 80, charging: false, hand: "right"))
        #expect(status.mode == "media")
        #expect(status.you == 1)
        #expect(status.hosts.count == 2)
        #expect(status.activeHost?.name == "iPhone")
        #expect(status.hosts[1].isComputer)
        #expect(status.hosts[1].type == .mac)
        #expect(status.update?.state == "idle")
        #expect(status.mouse == nil)
    }

    @Test func decodesBandPower() throws {
        let json = #"{"band":{"s":"live","bat":70,"chg":true,"hand":"left","mv":4205,"ma":-76}}"#
        let band = try #require(try DongleStatus.decode(Data(json.utf8)).band)
        #expect(band == DongleStatus.Band(state: "live", battery: 70, charging: true, hand: "left", millivolts: 4205, milliamps: -76))
    }

    @Test func decodesHostTypes() throws {
        let json = #"{"hosts":[{"h":1,"k":"computer","os":"windows","n":"PC","act":true},{"h":2,"k":"tv","n":"TV","act":false},{"h":3,"k":"computer","n":"Old","act":false}]}"#
        let status = try DongleStatus.decode(Data(json.utf8))
        #expect(status.hosts.map(\.type) == [.windows, .tv, .mac])
        #expect(status.hosts[1].isTV && !status.hosts[1].isComputer)
    }

    @Test func decodesMouseSettings() throws {
        let json = #"{"fw":"0.9.1","mode":"write","mouse":{"sp":7,"fx":true,"fy":false,"ty":false}}"#
        let status = try DongleStatus.decode(Data(json.utf8))
        #expect(status.mode == "write")
        #expect(status.mouse == DongleStatus.Mouse(speed: 7, flipX: true, flipY: false, typing: false))
    }

    @Test func nullsAndMissingFieldsDecode() throws {
        let json = #"{"fw":"0.6.1","id":"aa","verify":true,"band":{"s":"no-owner","bat":null,"chg":null,"hand":null},"hosts":[{"h":3}]}"#
        let status = try DongleStatus.decode(Data(json.utf8))
        #expect(status.onProbation)
        #expect(status.band?.state == "no-owner")
        #expect(status.band?.battery == nil)
        #expect(status.hosts == [DongleStatus.Host(handle: 3, kind: "phone", name: "", active: false)])
        #expect(status.you == nil)
        #expect(status.update == nil)
        #expect(status.pairingSecondsLeft == 0)
    }

    @Test func rejectsGarbage() {
        #expect(throws: (any Error).self) { try DongleStatus.decode(Data("not json".utf8)) }
    }
}

@Suite struct DongleCommandTests {
    @Test func texts() {
        #expect(DongleCommand.hello(name: "Shlok's iPhone").text == "hello Shlok's iPhone")
        #expect(DongleCommand.target(2).text == "target 2")
        #expect(DongleCommand.targetNext.text == "target next")
        #expect(DongleCommand.mode(.slides).text == "mode slides")
        #expect(DongleCommand.mouseSpeed(7).text == "mouse speed 7")
        #expect(DongleCommand.mouseSpeed(42).text == "mouse speed 10")
        #expect(DongleCommand.mouse(.flipX, true).text == "mouse flipx on")
        #expect(DongleCommand.mouse(.typing, false).text == "mouse type off")
        #expect(DongleCommand.pair(.computer).text == "pair computer")
        #expect(DongleCommand.pairClose.text == "pair close")
        #expect(DongleCommand.pairType(.windows).text == "pair windows")
        #expect(DongleCommand.hostType(3, .tv).text == "kind 3 tv")
        #expect(DongleCommand.name(2, " Work\nMac ").text == "name 2 Work Mac")
        #expect(DongleCommand.forget(4).text == "forget 4")
        #expect(DongleCommand.bandPause.text == "band pause")
        #expect(DongleCommand.key("teamsmute").data == Data("key teamsmute".utf8))
    }

    @Test func namesAreCutOnCharacterBoundaries() {
        let long = String(repeating: "é", count: 40)
        let cleaned = DongleCommand.clean(long)
        #expect(cleaned.utf8.count == 32)
        #expect(cleaned == String(repeating: "é", count: 16))
    }
}

@Suite struct DongleLogTests {
    @Test func reassemblesFragments() {
        var log = DongleLogAssembler()
        #expect(log.feed(Data("I (12) boot".utf8)).isEmpty)
        #expect(log.pending == "I (12) boot")
        #expect(log.feed(Data(" ok\r\nW (13) band".utf8)) == ["I (12) boot ok"])
        #expect(log.feed(Data(" lost\n\n".utf8)) == ["W (13) band lost", ""])
        #expect(log.pending.isEmpty)
    }
}

@Suite struct DonglePackageTests {
    static func makePackage(image: Data, version: String = "0.6.1", lengthDelta: Int = 0) -> Data {
        var header = Data(DonglePackageHeader.magic)
        header += UpdateFrame.le32(image.count + lengthDelta)
        header += Data(count: 4)
        header += Data(version.utf8) + Data(count: 48 - version.utf8.count)
        header += Data(SHA256.hash(data: image))
        header += Data(repeating: 0xEE, count: 64)
        header += Data(count: 96)
        return header + image
    }

    static func hex(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    let image = Data((0..<5000).map { UInt8(truncatingIfNeeded: $0 * 7) })

    @Test func parsesTheHeader() throws {
        let file = Self.makePackage(image: image)
        let header = try DonglePackageHeader(file)
        #expect(header.imageLength == 5000)
        #expect(header.version == "0.6.1")
        #expect(header.signature == Data(repeating: 0xEE, count: 64))
        let package = try DonglePackage(file, expectedSHA256: Self.hex(file).uppercased(), expectedSize: file.count)
        #expect(package.header == header)
        #expect(package.sha256 == Self.hex(file))
    }

    @Test func rejectsBadPackages() {
        var wrongMagic = Self.makePackage(image: image)
        wrongMagic[5] = 0x02
        #expect(throws: DonglePackageError.badMagic) { try DonglePackageHeader(wrongMagic) }
        #expect(throws: DonglePackageError.tooShort(100)) { try DonglePackageHeader(Data(count: 100)) }

        let short = Self.makePackage(image: image, lengthDelta: 1)
        #expect(throws: DonglePackageError.lengthMismatch(header: 5001, file: short.count)) {
            try DonglePackage(short, expectedSHA256: Self.hex(short))
        }
        let good = Self.makePackage(image: image)
        #expect(throws: DonglePackageError.checksumMismatch) { try DonglePackage(good, expectedSHA256: String(repeating: "0", count: 64)) }
        #expect(throws: DonglePackageError.sizeMismatch(index: 1, file: good.count)) { try DonglePackage(good, expectedSHA256: Self.hex(good), expectedSize: 1) }

        var tampered = good
        tampered[tampered.count - 1] ^= 1
        #expect(throws: DonglePackageError.imageChecksumMismatch) { try DonglePackage(tampered, expectedSHA256: Self.hex(tampered)) }
    }
}

@Suite struct DongleReleaseTests {
    @Test func decodesAndResolvesRelativeFiles() throws {
        let json = #"{"version":"0.6.0","id":"3fa2c1d0","file":"bandit-3fa2c1d0.banditfw","size":1650000,"sha256":"ab","notes":"…","flasher":"bandit-3fa2c1d0-flasher.html"}"#
        let index = try #require(DongleRelease.indexURL(host: "my-mac.example.ts.net"))
        #expect(index.absoluteString == "https://my-mac.example.ts.net/dongle/latest.json")
        let release = try DongleRelease.decode(Data(json.utf8), index: index)
        #expect(release.size == 1_650_000)
        #expect(release.packageURL?.absoluteString == "https://my-mac.example.ts.net/dongle/bandit-3fa2c1d0.banditfw")
        #expect(release.flasherURL?.absoluteString == "https://my-mac.example.ts.net/dongle/bandit-3fa2c1d0-flasher.html")
    }

    @Test func noHostNoIndex() {
        #expect(DongleRelease.indexURL(host: " ") == nil)
        #expect(DongleRelease.indexURL(host: "https://x/y") == nil)
    }
}

@Suite struct DongleUpdateFrameTests {
    @Test func encodesFrames() {
        #expect(UpdateFrame.begin(total: 0x0102_0304) == Data([0x01, 0x04, 0x03, 0x02, 0x01]))
        #expect(UpdateFrame.data(offset: 256, Data([0xAA])) == Data([0x02, 0x00, 0x01, 0x00, 0x00, 0xAA]))
        #expect(UpdateFrame.abort == Data([0x03]))
    }

    @Test func decodesNotifications() {
        #expect(DongleUpdateMessage(Data([0x80])) == .ready)
        #expect(DongleUpdateMessage(Data([0x81, 0x00, 0x10, 0x00, 0x00])) == .ack(next: 4096))
        #expect(DongleUpdateMessage(Data([0x82, 0x10, 0x00, 0x00, 0x00])) == .resend(next: 16))
        #expect(DongleUpdateMessage(Data([0x83])) == .done)
        #expect(DongleUpdateMessage(Data([0x84]) + Data("bad signature".utf8)) == .fail("bad signature"))
        #expect(DongleUpdateMessage(Data([0x81, 0x00])) == nil)
        #expect(DongleUpdateMessage(Data()) == nil)
        #expect(DongleUpdateMessage(Data([0x99])) == nil)
    }
}

@Suite struct DongleTransferTests {
    /// `#expect` can't call mutating members directly.
    func call<T>(_ transfer: inout DongleTransfer, _ body: (inout DongleTransfer) -> T) -> T { body(&transfer) }

    func drain(_ transfer: inout DongleTransfer) -> [Range<Int>] {
        var chunks: [Range<Int>] = []
        while let chunk = transfer.nextChunk() { chunks.append(chunk) }
        return chunks
    }

    @Test func keepsAtMostTheWindowInFlight() {
        var transfer = DongleTransfer(total: 20_000, chunkSize: 1000, now: 0)
        let first = drain(&transfer)
        #expect(first.count == 8)
        #expect(first.first == 0..<1000)
        #expect(transfer.inFlight == 8000)
        transfer.ack(4096, now: 1)
        let second = drain(&transfer)
        #expect(second.first == 8000..<9000)
        #expect(transfer.inFlight <= DongleTransfer.window)
        #expect(transfer.next == 12_000)
    }

    @Test func lastChunkIsShortAndCompletes() {
        var transfer = DongleTransfer(total: 2500, chunkSize: 1000, now: 0)
        #expect(drain(&transfer) == [0..<1000, 1000..<2000, 2000..<2500])
        #expect(!transfer.allAcknowledged)
        transfer.ack(2500, now: 1)
        #expect(transfer.allAcknowledged)
        #expect(call(&transfer) { $0.nextChunk() } == nil)
        #expect(!call(&transfer) { $0.checkTimeout(now: 100) })
    }

    @Test func resendRewinds() {
        var transfer = DongleTransfer(total: 10_000, chunkSize: 500, now: 0)
        _ = drain(&transfer)
        transfer.resend(from: 1500, now: 2)
        #expect(transfer.acked == 1500)
        #expect(call(&transfer) { $0.nextChunk() } == 1500..<2000)
        #expect(transfer.resends == 1)
    }

    @Test func staleAcksDontMoveBackwards() {
        var transfer = DongleTransfer(total: 10_000, chunkSize: 500, now: 0)
        _ = drain(&transfer)
        transfer.ack(4096, now: 1)
        transfer.ack(2048, now: 2)
        #expect(transfer.acked == 4096)
        #expect(transfer.lastProgress == 1)
    }

    @Test func timeoutResendsFromLastAckAndEventuallyGivesUp() {
        var transfer = DongleTransfer(total: 50_000, chunkSize: 500, now: 0)
        _ = drain(&transfer)
        #expect(!call(&transfer) { $0.checkTimeout(now: 4.9) })
        #expect(call(&transfer) { $0.checkTimeout(now: 5) })
        #expect(transfer.next == 0)
        #expect(call(&transfer) { $0.nextChunk() } == 0..<500)
        for i in 2...DongleTransfer.maxStalls {
            _ = drain(&transfer)
            #expect(call(&transfer) { $0.checkTimeout(now: 5 * Double(i)) })
        }
        #expect(transfer.gaveUp)
        #expect(call(&transfer) { $0.nextChunk() } == nil)
    }

    @Test func ackResetsStalls() {
        var transfer = DongleTransfer(total: 50_000, chunkSize: 500, now: 0)
        _ = drain(&transfer)
        #expect(call(&transfer) { $0.checkTimeout(now: 5) })
        _ = drain(&transfer)
        transfer.ack(4096, now: 6)
        #expect(transfer.stalls == 0)
    }

    @Test func oversizedChunksStillFitTheWindow() {
        var transfer = DongleTransfer(total: 100_000, chunkSize: 100_000, now: 0)
        #expect(call(&transfer) { $0.nextChunk() } == 0..<DongleTransfer.window)
        #expect(call(&transfer) { $0.nextChunk() } == nil)
    }
}
