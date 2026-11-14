import CryptoKit
import Foundation
import Testing
@testable import BandCredentials
@testable import BandProtocol

private func seq(_ range: Range<UInt8>) -> [UInt8] { Array(range) }

// MARK: - Crypto vectors from band-core tests/airshield.rs

@Suite struct AirShieldVectors {
    let first = [UInt8](hex: "40c9f748fb0f0ae8e0018675352ee743a1e58ccd288d25d27f6e72551887e4aad6fc68175e7287a1eee1")!
    let second = [UInt8](hex: "4038cb0decaa0692b900d5962230f8734c8a3de4d262936261f1")!

    @Test func scheme3KeyDerivationMatchesPythonVector() throws {
        let keys = try AirShieldKeys.derive(.scheme3, secret: seq(0..<32), challenge: seq(0..<16), seed: seq(32..<64))
        #expect(keys.encryptionKeyForTesting.hex == "5080496832e72e0a4de90f22e7797a3c6277197b4bd29f296bd7142850db1998")
        #expect(keys.macKeyForTesting == keys.encryptionKeyForTesting)
        #expect(throws: BandError.self) { try AirShieldKeys.derive(.scheme3, secret: seq(0..<31), challenge: seq(0..<16), seed: seq(32..<64)) }
    }

    @Test func receiverDecryptsSplitRecordsAndSkipsControlMarkers() throws {
        let keys = AirShieldKeys.fixed(encryption: seq(0..<32), mac: seq(0..<32))
        var receiver = AirShieldReceiver(cipher: AirShieldCipher(keys: keys, iv: seq(0..<16), counter: .max))
        var decoded: [[UInt8]] = []
        for byte in first + [0x81, 0, 1, 2, 42, 43, 44] + second { decoded += try receiver.feed([byte]) }
        #expect(receiver.isDrained)
        #expect(decoded == [Array("first block.....second block....".utf8), Array("last block......".utf8)])
        #expect(receiver.cipher.counter == 1, "the counter wraps")
        var sender = AirShieldCipher(keys: keys, iv: seq(0..<16), counter: .max)
        #expect(try sender.encrypt(decoded[0]) == first)
        #expect(try sender.encrypt(decoded[1]) == second)
    }

    @Test func tamperedPacketsAreRejectedWithoutStateChange() throws {
        let keys = AirShieldKeys.fixed(encryption: seq(0..<32), mac: seq(0..<32))
        for index in [1, 12] {
            var corrupted = first
            corrupted[index] ^= 1
            var receiver = AirShieldReceiver(cipher: AirShieldCipher(keys: keys, iv: seq(0..<16), counter: .max))
            #expect(throws: BandError.self) { try receiver.feed(corrupted) }
            #expect(receiver.cipher.counter == .max)
            #expect(receiver.cipher.iv == seq(0..<16))
        }
    }

    @Test func scheme31MatchesPublicVectors() throws {
        let secret = [UInt8](hex: "f2f6f1f1a56fb52122ec338ed887338b42b976290253dbd6f48f3cc0b15b2ba8")!
        let rx = try AirShieldKeys.derive(.scheme31, secret: secret, challenge: [UInt8](hex: "c75051fb3e50142ba10c15a023777c6b")!,
                                          seed: [UInt8](repeating: UInt8(ascii: "A"), count: 32))
        #expect(rx.encryptionKeyForTesting.hex == "d70b81653601bbc46f13c6749324fa2b680af0064592a2c663a0891d7a43875d")
        let tx = try AirShieldKeys.derive(.scheme31, secret: secret, challenge: Array("0123456789abcdef".utf8),
                                          seed: [UInt8](hex: "c58e0f4bf291a0b2f50a40955b0bd53c9c7fd5a9f5fdbf7b14272efed585ca14")!)
        #expect(tx.encryptionKeyForTesting.hex == "2f72596312c1120bf869dd69b0c6b4aa6cc05981723a45a4bb294343a11793cc")
        var cipher = AirShieldCipher(keys: tx, iv: [UInt8](repeating: 0, count: 16), counter: 0xba8d_8b80)
        do { _ = try cipher.decrypt([UInt8](hex: "40f4d00bc5a22d9ecd0055ff7a63ea6ac9f1723721ffa9d7f4a7")!) } catch let error as BandError {
            #expect(!(error.errorDescription ?? "").contains("authentication"))
        }
    }

    @Test func hapticsEncodingMatchesBandCore() throws {
        #expect(try HapticsCommand.vibrate(durationMs: 100, amplitude: 255).encodeRPC(sequence: 1)
                == [0x08, 0x01, 0x8a, 0x01, 0x07, 0x0a, 0x05, 0x08, 0x64, 0x18, 0xff, 0x01])
        #expect(try HapticsCommand.perform(patternID: 2).encodeRPC(sequence: 2) == [0x08, 0x02, 0x8a, 0x01, 0x04, 0x12, 0x02, 0x08, 0x02])
    }

    @Test func dataXPaddingAndTypedWords() throws {
        let frame = try DataX.encode(channel: 0x8005, words: [0x8100_ce56, 0x0200_0314], payload: [1, 2, 3])
        var padded = frame + [UInt8](repeating: 0xc0 + UInt8(16 - frame.count % 16), count: 16 - frame.count % 16)
        if padded.count % 16 != 0 { padded += [] }
        var receiver = DataXReceiver()
        receiver.setAlwaysPadded()
        let frames = try receiver.feed(padded)
        #expect(frames == [DataXFrame(channel: 0x8005, words: [0x8100_ce56, 0x0200_0314], payload: [1, 2, 3])])
    }
}

// MARK: - Whole-session tests against the synthetic band

private struct Link {
    let session: BandSession
    let band: SimulatedBand
    var events: [SessionEvent] = []
    var time = 1.0

    init(session: BandSession, band: SimulatedBand) {
        self.session = session
        self.band = band
    }

    /// Pumps bytes both ways until quiet, feeding the band's bytes in small chunks like L2CAP would.
    mutating func pump(_ initial: [UInt8], pairRequest: ((CeremonyPairRequest) -> [UInt8])? = nil,
                       pair: ((CeremonyPair) -> [UInt8])? = nil) throws {
        var toBand = initial
        for _ in 0..<64 {
            let fromBand = try band.respond(toBand)
            toBand = []
            if fromBand.isEmpty { break }
            var index = 0
            while index < fromBand.count {
                let chunk = Array(fromBand[index..<min(index + 23, fromBand.count)])
                index += chunk.count
                time += 0.001
                let result = try session.feed(chunk, time: time)
                toBand += result.outgoing
                for event in result.events {
                    events.append(event)
                    if case .ceremonyHttp(.pairRequest(let request)) = event { toBand += pairRequest?(request) ?? [] }
                    if case .ceremonyHttp(.pair(let request)) = event { toBand += pair?(request) ?? [] }
                }
            }
        }
    }

    mutating func deliver(_ bytes: [UInt8]) throws -> [SessionEvent] {
        time += 0.01
        let result = try session.feed(bytes, time: time)
        _ = try band.respond(result.outgoing)
        events += result.events
        return result.events
    }
}

@Suite struct SessionTests {
    @Test func enrolledOwnerConnectsReceivesGesturesAndHaptics() throws {
        let owner = OwnerIdentity(privateKey: P256.Signing.PrivateKey())
        let band = SimulatedBand(mode: .enrolled)
        band.ownerHash = Array(SHA256.hash(data: owner.appPoint))
        var link = Link(session: BandSession(mode: .enrolled(owner)), band: band)
        try link.pump(link.session.request())

        #expect(link.session.guessing)
        #expect(link.events.contains { if case .ownerTrusted = $0 { true } else { false } })
        #expect(link.events.contains { if case .connected = $0 { true } else { false } })
        #expect(link.events.contains { if case .handedness(.right) = $0 { true } else { false } })
        #expect(link.session.deviceInfo?.firmware == "1054928927")
        #expect(link.session.streamsEnabled)

        // An index tap arrives twice (raw action, then derived); the router yields it once.
        var router = GestureRouter()
        var recognized: [RecognizedGesture] = []
        for bytes in [try band.gesture(finger: 2, action: 3, derived: 0), try band.gesture(finger: 2, action: 0, derived: 1)] {
            for event in try link.deliver(bytes) {
                if case .gesture(let message) = event, let gesture = router.route(message, now: link.time) { recognized.append(gesture) }
            }
        }
        #expect(recognized == [.tap(.index, .tap)])

        // Thumb swipe.
        for event in try link.deliver(try band.gesture(finger: 1, action: 8, derived: 7)) {
            if case .gesture(let message) = event, let gesture = router.route(message, now: link.time) { recognized.append(gesture) }
        }
        #expect(recognized.last == .swipe(.left))

        // Haptics once other requests are settled.
        _ = link.session.tick(time: link.time + 6)
        #expect(link.session.hapticsReady)
        let bytes = try link.session.sendHaptics(.vibrate(durationMs: 120, amplitude: 200), time: link.time)
        let answer = try band.respond(bytes)
        let events = try link.session.feed(answer, time: link.time + 0.1).events
        #expect(band.hapticsSeen.count == 1)
        #expect(events.contains { if case .hapticsFinished(_, true, true) = $0 { true } else { false } })

        // Battery.
        let battery = try band.respond(link.session.queryBatteryStatus(time: link.time))
        let batteryEvents = try link.session.feed(battery, time: link.time + 0.2).events
        #expect(batteryEvents.contains { if case .batteryStatus(let status) = $0 { status == BatteryStatus(level: 77, charging: true) } else { false } })

        // Clean stop.
        _ = try band.respond(link.session.stop())
    }

    @Test func wrongSchemeGuessFailsBeforeAnyPacketAuthenticates() throws {
        let owner = OwnerIdentity(privateKey: P256.Signing.PrivateKey())
        let band = SimulatedBand(mode: .enrolled)
        var link = Link(session: BandSession(mode: .enrolled(owner), schemeGuess: 1), band: band)
        #expect(throws: BandError.self) { try link.pump(link.session.request()) }
        #expect(link.session.authenticatedPackets == 0)
    }

    @Test func aDifferentOwnerKeyIsReportedAsMismatch() throws {
        let band = SimulatedBand(mode: .enrolled)
        band.ownerHash = [UInt8](repeating: 1, count: 32)
        var link = Link(session: BandSession(mode: .enrolled(OwnerIdentity(privateKey: .init()))), band: band)
        do {
            try link.pump(link.session.request())
            Issue.record("expected a mismatch")
        } catch let error as BandError {
            #expect(error.code == 0x1043)
        }
    }

    @Test func ceremonyClaimsTheBandThenTrustsTheNewKey() throws {
        let band = SimulatedBand(mode: .ceremony)
        var link = Link(session: BandSession(mode: .ceremony), band: band)
        let session = link.session
        var pendingBeforeFinish: OwnerIdentity?
        try link.pump(session.request(), pairRequest: { request in
            #expect(request.identity.serial == "SIMBAND0001")
            #expect(request.nonce.count == 16)
            return (try? session.ceremonyPairRequestCompleted(signature: [1, 2, 3], receipt: "{\"pending\":1}")) ?? []
        }, pair: { pair in
            #expect(pair.receipt.contains("DevicePendingOwnershipReceipt"))
            let bytes = (try? session.ceremonyPairCompleted(signature: [4, 5], receipt: "{\"final\":1}", devicePublicKey: band.bandPoint)) ?? []
            pendingBeforeFinish = session.pendingIdentity
            return bytes
        })
        #expect(band.finishSeen)
        #expect(pendingBeforeFinish != nil)
        let completed = link.events.compactMap { event -> OwnerIdentity? in
            if case .ceremonyCompleted(let identity) = event { identity } else { nil }
        }
        #expect(completed.count == 1)
        #expect(completed.first?.verifiesBand == true, "the band key from Meta verifies the band's proof")
        #expect(link.events.contains { if case .connected = $0 { true } else { false } })
        #expect(Array(SHA256.hash(data: completed[0].appPoint)) == band.ownerHash)
    }

    /// Firmware 79a235830f7f (scheme 3) sends its trust proof as soon as the identity service opens
    /// and only answers the identity read once that proof is acknowledged.
    @Test func olderFirmwareEarlyProofIsAcknowledgedAndTheClaimContinues() throws {
        let band = SimulatedBand(mode: .ceremony, variant: .scheme3)
        band.earlyProof = true
        var link = Link(session: BandSession(mode: .ceremony), band: band)
        let session = link.session
        var reachedPairRequest = false
        try link.pump(session.request(), pairRequest: { _ in
            reachedPairRequest = true
            return []
        })
        #expect(!session.guessing, "scheme 3 band")
        #expect(band.earlyProofAcked)
        #expect(reachedPairRequest, "the band answered the identity read after the ack")
        #expect(session.takeNotes().contains { $0.text.contains("before the identity read") })
    }

    @Test func legacyStartupStreamsWithoutAKey() throws {
        let band = SimulatedBand(mode: .legacy, variant: .scheme3)
        band.earlyProof = true
        var link = Link(session: BandSession(mode: .legacy), band: band)
        try link.pump(link.session.request())
        #expect(band.earlyProofAcked)
        #expect(link.events.contains { if case .connected = $0 { true } else { false } })
        let events = try link.deliver(try band.gesture(finger: 3, action: 4, derived: 2))
        #expect(events.contains { if case .gesture(let message) = $0 { message.finger == "middle" } else { false } })
    }

    /// The handwriting capture finds the settings by name, switches the model on, decodes, and puts the
    /// band's own values back, verified, without ever writing the decoy `settings-reset`.
    @Test(arguments: [false, true]) func handwritingCaptureRunsAndRestoresTheBand(newerLayout: Bool) throws {
        let owner = OwnerIdentity(privateKey: P256.Signing.PrivateKey())
        let band = SimulatedBand(mode: .enrolled, variant: .scheme3)
        if newerLayout {
            // Updated firmware: more settings, and the two handwriting ones moved.
            band.settings = [26: ("settings-reset", 0), 27: ("wrist-wake", 1), 28: ("haptics-level", 2),
                             33: ("data-collection", 0), 34: ("data-collection-model", 2), 36: ("ota-channel", 0)]
            band.logsWhenCollecting = true
            band.refusesConfigService = true
        }
        band.ownerHash = Array(SHA256.hash(data: owner.appPoint))
        var link = Link(session: BandSession(mode: .enrolled(owner)), band: band)
        let session = link.session
        try link.pump(session.request())
        try session.startHandwriting(time: link.time)
        var statuses: [ModelCaptureStatus] = []
        var decoder = HandwritingDecoder()
        func run(seconds: Double, write letters: [Int] = []) throws {
            var pendingLetters = letters
            let end = link.time + seconds
            while link.time < end {
                link.time += 0.05
                let flushed = try session.flushModelCapture(time: link.time)
                statuses += flushed.events.compactMap { if case .modelCaptureState(let s) = $0 { s } else { nil } }
                if !flushed.outgoing.isEmpty {
                    let answer = try band.respond(flushed.outgoing)
                    let result = try session.feed(answer, time: link.time)
                    statuses += result.events.compactMap { if case .modelCaptureState(let s) = $0 { s } else { nil } }
                }
                if band.handwritingOn {
                    let index = pendingLetters.isEmpty ? Handwriting.blank : pendingLetters.removeFirst()
                    for event in try session.feed(try band.inference(best: index), time: link.time).events {
                        if case .inferenceSample(let sample) = event { decoder.push(sample.values) }
                        if case .modelCaptureState(let s) = event { statuses.append(s) }
                    }
                }
            }
        }
        try run(seconds: 3)
        #expect(session.handwritingStatus.phase == .ready, "\(statuses.map(\.message))")
        #expect(band.setting("data-collection") == 1 && band.setting("data-collection-model") == 5)
        try run(seconds: 1, write: [7, 7, Handwriting.blank, 8, Handwriting.blank]) // "h h _ i _"
        #expect(decoder.text == "hi")
        session.stopHandwriting(time: link.time)
        try run(seconds: 3)
        #expect(session.handwritingStatus.phase == .finished)
        #expect(session.handwritingStatus.restorationVerified)
        #expect(band.setting("data-collection") == 0 && band.setting("data-collection-model") == 2, "the band's own values are back")
        #expect(Set(band.settingWrites.map(\.0)) == (newerLayout ? [33, 34] : [27, 28]), "only the two named settings are written")
        #expect(!band.modelStreams)
        #expect(!band.settingWrites.contains { $0.0 == 26 }, "settings-reset is never written")
    }

    @Test func surveyReadsEverythingAndWritesNothing() throws {
        let owner = OwnerIdentity(privateKey: P256.Signing.PrivateKey())
        let band = SimulatedBand(mode: .enrolled, variant: .scheme3)
        band.ownerHash = Array(SHA256.hash(data: owner.appPoint))
        var link = Link(session: BandSession(mode: .enrolled(owner)), band: band)
        let session = link.session
        try link.pump(session.request())
        try session.startSurvey(time: link.time)
        let end = link.time + 120
        while link.time < end, session.surveyReport.phase != .finished {
            link.time += 0.05
            let flushed = try session.flushModelCapture(time: link.time)
            if !flushed.outgoing.isEmpty { _ = try session.feed(try band.respond(flushed.outgoing), time: link.time) }
        }
        let report = session.surveyReport
        #expect(report.phase == .finished, "\(report.message)")
        #expect(report.settingsCount == 28)
        #expect(report.settings.first { $0.id == 27 }?.name == "data-collection")
        #expect(report.settings.first { $0.id == 27 }?.valueKind == "bool")
        #expect(report.settings.first { $0.id == 28 }?.value == "2")
        #expect(report.settings.first { $0.id == 26 }?.dangerous == true)
        #expect(report.settings.first { $0.id == 3 }?.problem != nil, "missing ids are reported, not fatal")
        #expect(report.ota?.stateName == "idle")
        #expect(report.ota?.activeFirmware == 100)
        #expect(report.ota?.mlModel == 5)
        #expect(report.config.first?.field == 1)
        #expect(band.settingWrites.isEmpty, "the survey never writes")
    }

    @Test func experimentalStreamsToggleAndStopTurnsThemOff() throws {
        let owner = OwnerIdentity(privateKey: P256.Signing.PrivateKey())
        let band = SimulatedBand(mode: .enrolled, variant: .scheme3)
        band.ownerHash = Array(SHA256.hash(data: owner.appPoint))
        var link = Link(session: BandSession(mode: .enrolled(owner)), band: band)
        let session = link.session
        try link.pump(session.request())
        #expect(throws: (any Error).self) { try session.setProbeStreams([3], time: link.time) }
        let events = try session.feed(try band.respond(try session.setProbeStreams([29, 4], time: link.time)), time: link.time).events
        let reported = events.compactMap { if case .probeStreams(let flags) = $0 { flags } else { nil } }.first
        #expect(reported?[29] == 1)
        #expect(band.modelStreams)
        #expect(throws: (any Error).self) { try session.startHandwriting(time: link.time) }
        _ = try band.respond(try session.stop())
        #expect(band.extraStreams[29] == 0)
        #expect(!band.modelStreams)
    }

    private func connectedLink() throws -> Link {
        let owner = OwnerIdentity(privateKey: P256.Signing.PrivateKey())
        let band = SimulatedBand(mode: .enrolled, variant: .scheme3)
        band.ownerHash = Array(SHA256.hash(data: owner.appPoint))
        var link = Link(session: BandSession(mode: .enrolled(owner)), band: band)
        try link.pump(link.session.request())
        return link
    }

    private func otaPlan(_ mode: OtaMode, version: UInt64 = 200) -> OtaPlan {
        let firmware = (0..<5000).map { UInt8(truncatingIfNeeded: $0 &* 7) }
        let model = (0..<12_000).map { UInt8(truncatingIfNeeded: $0 &* 13) }
        return OtaPlan(version: version, firmware: firmware, firmwareMD5: Array(Insecure.MD5.hash(data: firmware)),
                       model: (model, Array(Insecure.MD5.hash(data: model))), kek: (20, [UInt8](repeating: 9, count: 32)), mode: mode)
    }

    /// Runs an update step against the simulated band until it stops talking; the reports seen.
    private func runOta(_ link: inout Link, _ plan: OtaPlan) throws -> [OtaReport] {
        let start = try link.session.otaStart(plan, time: link.time)
        let before = link.events.count
        try link.pump(start.outgoing)
        return (start.events + link.events[before...]).compactMap { if case .otaProgress(let report) = $0 { report } else { nil } }
    }

    @Test func updateInstallsTheKeySendsBothItemsAndCommits() throws {
        var link = try connectedLink()
        let plan = otaPlan(.update)
        let reports = try runOta(&link, plan)
        let log = reports.flatMap(\.lines).joined(separator: "\n")
        let band = link.band
        #expect(band.ota.kek == 20, "\(log)")
        #expect(band.ota.verified[0] == plan.firmware && band.ota.verified[2] == plan.model?.data, "\(log)")
        #expect(band.ota.committed && band.ota.active == 200, "\(log)")
        #expect(reports.last?.commitAccepted == true && reports.last?.running == false, "\(log)")
        #expect(!link.session.otaRunning)
        #expect(band.ota.steps.first == 1 && band.ota.steps.last == 4, "status first, commit last: \(band.ota.steps)")
    }

    @Test func trialSendsEverythingThenAbortsAndNothingStaysStaged() throws {
        var link = try connectedLink()
        let reports = try runOta(&link, otaPlan(.trial))
        let log = reports.flatMap(\.lines).joined(separator: "\n")
        #expect(log.contains("TRIAL OK"), "\(log)")
        #expect(!link.band.ota.committed && link.band.ota.active == 100 && link.band.ota.staged == 100)
        #expect(!link.band.ota.steps.contains(4), "a trial never commits")
        #expect(!reports.contains { $0.committed })
    }

    @Test func anOlderPackageIsRefusedAndTheTrialCleansUp() throws {
        var link = try connectedLink()
        let reports = try runOta(&link, otaPlan(.trial, version: 50))
        let log = reports.flatMap(\.lines).joined(separator: "\n")
        #expect(log.contains("REJECTED_OLD_VERSION"), "\(log)")
        #expect(link.band.ota.steps.last == 1 || link.band.ota.steps.last == 5, "\(link.band.ota.steps)")
        #expect(!link.band.ota.committed)
        #expect(!link.session.otaRunning)
    }

    @Test func installOnlyCommitsWhatIsStaged() throws {
        var link = try connectedLink()
        let nothing = try runOta(&link, otaPlan(.install))
        #expect(nothing.flatMap(\.lines).joined().contains("isn't staged"))
        #expect(!link.band.ota.steps.contains(4))
        _ = try runOta(&link, otaPlan(.key))
        let staged = try runOta(&link, otaPlan(.send))
        #expect(staged.flatMap(\.lines).joined().contains("STAGED"), "\(staged.flatMap(\.lines))")
        #expect(link.band.ota.state == 3 && !link.band.ota.committed)
        let installed = try runOta(&link, otaPlan(.install))
        #expect(installed.last?.commitAccepted == true, "\(installed.flatMap(\.lines))")
        #expect(link.band.ota.active == 200)
    }

    @Test func lateChunksAreResentAndSilenceFailsTheStep() {
        let job = OtaJob(plan: OtaPlan(version: 64, firmware: [UInt8](repeating: 0, count: 3000), firmwareMD5: [UInt8](repeating: 0, count: 16),
                                       model: nil, kek: nil, mode: .trial))
        func reply(_ seq: UInt64, _ field: UInt32, _ body: [UInt8]) -> ProtoFields {
            try! ProtoFields(parsing: Proto.field(1, seq) + Proto.field(2, 1) + Proto.field(field, bytes: body))
        }
        func seqOf(_ body: [UInt8]) -> UInt64 { try! ProtoFields(parsing: body).integer(1) }
        let status = Proto.field(2, bytes: Proto.field(4, 1) + Proto.field(5, bytes: Proto.field(1, 0) + Proto.field(2, 1)) + Proto.field(6, 20))
        var ids: UInt64 = 0
        let first = job.begin(ids: &ids, now: 0)
        let start = job.receive(reply(seqOf(first[0]), 8, status), ids: &ids, now: 0.1)
        let info = job.receive(reply(seqOf(start[0]), 8, Proto.field(1, bytes: Proto.field(1, bytes: Proto.field(1, 0)))), ids: &ids, now: 0.2)
        let chunks = job.receive(reply(seqOf(info[0]), 10, Proto.field(1, bytes: Proto.field(1, 1) + Proto.field(2, 2 * 950))), ids: &ids, now: 0.3)
        #expect(chunks.count == 2)
        #expect(job.tick(ids: &ids, now: 1).isEmpty)
        let again = job.tick(ids: &ids, now: 5.4)
        #expect(again.count == 2)
        #expect(!job.owns(seqOf(chunks[0])))
        #expect(job.owns(seqOf(again[0])))
        #expect(job.cancellable)
    }

    @Test func handwritingDecoderMergesRepeatsAndHonorsBlanks() {
        func frame(_ best: Int) -> [Float] {
            var scores = [Float](repeating: -20, count: 100)
            scores[best] = 0
            return scores
        }
        var decoder = HandwritingDecoder()
        for index in [7, 7, Handwriting.blank, 4, 11, 11, Handwriting.blank, 11, 14, Handwriting.blank] { decoder.push(frame(index)) }
        #expect(decoder.text == "hello")
        var paused = HandwritingDecoder()
        for index in [0, Handwriting.pause, 1] { paused.push(frame(index)) }
        #expect(paused.text == "ab")
        #expect(Handwriting.symbol(62) == "!")
        #expect(Handwriting.symbol(96) == "▁")
    }

    @Test func wrongAccountClaimIsRejectedWithCode() throws {
        let band = SimulatedBand(mode: .ceremony)
        band.rejectClaim = 0x0300_1042
        var link = Link(session: BandSession(mode: .ceremony), band: band)
        let session = link.session
        do {
            try link.pump(session.request(), pairRequest: { _ in
                (try? session.ceremonyPairRequestCompleted(signature: [1], receipt: "{}")) ?? []
            })
            Issue.record("expected a rejection")
        } catch let error as BandError {
            #expect(error.code == 0x1042)
        }
    }

    @Test func pinchDialTurnsWhileIndexIsHeld() throws {
        let owner = OwnerIdentity(privateKey: P256.Signing.PrivateKey())
        let band = SimulatedBand(mode: .enrolled)
        band.ownerHash = Array(SHA256.hash(data: owner.appPoint))
        var link = Link(session: BandSession(mode: .enrolled(owner)), band: band)
        try link.pump(link.session.request())
        var stamp: UInt64 = 1_000_000
        _ = try link.deliver(try band.gyro(0, 0, 0, timestamp: stamp))
        _ = try link.deliver(try band.gesture(finger: 2, action: 1, derived: 0)) // index press
        var turned = 0.0
        var engaged = false
        for _ in 0..<40 {
            stamp += 10_000
            for event in try link.deliver(try band.gyro(1000, 0, 0, timestamp: stamp)) {
                if case .dialState(true) = event { engaged = true }
                if case .dialTurn(let delta) = event { turned += delta }
            }
        }
        #expect(engaged)
        #expect(turned > 1)
    }
}

// MARK: - Credential formats

@Suite struct CredentialFormatTests {
    @Test func airGesturesBundleRoundTripsAndMatchesSchema() throws {
        let identity = OwnerIdentity(privateKey: .init(), bandPublicKey: P256.Signing.PrivateKey().publicKey)
        let band = AirGesturesBand(address: "A4:0E:2B:90:A6:64", name: "Meta Band 00DF", schemeGuess: 0)
        let data = AirGesturesFile.encode(identity: identity, band: band)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(json["format"] as? String == "air-gestures-band")
        #expect(json["version"] as? Int == 1)
        #expect(Data(base64Encoded: json["owner_key"] as! String)?.count == 97)
        #expect((json["band"] as? [String: Any])?["scheme_guess"] as? Int == 0)
        let parsed = try AirGesturesFile.parse(data)
        #expect(parsed.identity.ownerKeyBytes == identity.ownerKeyBytes)
        #expect(parsed.band == band)
        #expect(String(data: data, encoding: .utf8)!.hasSuffix("}\n"))

        let keyOnly = AirGesturesFile.encode(identity: OwnerIdentity(privateKey: .init()), band: nil)
        let keyJSON = try JSONSerialization.jsonObject(with: keyOnly) as! [String: Any]
        #expect(keyJSON["band"] == nil)
        #expect(Data(base64Encoded: keyJSON["owner_key"] as! String)?.count == 32)
    }

    @Test func parsesTheExactFileAirGesturesWrites() throws {
        let key = OwnerIdentity(privateKey: .init())
        let text = """
        {
          "format": "air-gestures-band",
          "version": 1,
          "owner_key": "\(Data(key.ownerKeyBytes).base64EncodedString())",
          "band": {
            "address": "AA:BB:CC:DD:EE:FF",
            "name": "Meta Band 1234",
            "scheme_guess": 0
          }
        }

        """
        let parsed = try AirGesturesFile.parse(Data(text.utf8))
        #expect(parsed.band?.schemeGuess == 0)
        #expect(AirGesturesFile.encode(identity: parsed.identity, band: parsed.band) == Data(text.utf8))
    }

    @Test func badFilesAreRejected() throws {
        func bundle(_ format: String, _ version: Int, _ key: [UInt8]) -> Data {
            try! JSONSerialization.data(withJSONObject: ["format": format, "version": version, "owner_key": Data(key).base64EncodedString()])
        }
        let key = OwnerIdentity(privateKey: .init()).ownerKeyBytes
        #expect(throws: AirGesturesFile.ParseError.self) { try AirGesturesFile.parse(bundle("something-else", 1, key)) }
        #expect(throws: AirGesturesFile.ParseError.newerVersion(2)) { try AirGesturesFile.parse(bundle("air-gestures-band", 2, key)) }
        #expect(throws: AirGesturesFile.ParseError.self) { try AirGesturesFile.parse(bundle("air-gestures-band", 1, Array(key.prefix(31)))) }
        #expect(throws: AirGesturesFile.ParseError.self) { try AirGesturesFile.parse(bundle("air-gestures-band", 1, [UInt8](repeating: 0, count: 32))) }
        #expect(throws: AirGesturesFile.ParseError.self) { try AirGesturesFile.parse(Data(repeating: 1, count: 40)) }
        // A raw owner.key imports without a band record.
        let raw = try AirGesturesFile.parse(Data(key))
        #expect(raw.rawKey && raw.band == nil)
    }

    @Test func encryptedBackupRoundTripsAndRejectsWrongPassword() throws {
        let plain = AirGesturesFile.encode(identity: OwnerIdentity(privateKey: .init()), band: nil)
        let sealed = try EncryptedBackup.encrypt(airGesturesJSON: plain, password: "correct horse battery", bandName: "Meta Band 1",
                                                 fingerprint: "AAAA", iterations: 100_000)
        #expect(EncryptedBackup.isBackup(sealed))
        #expect(!EncryptedBackup.isBackup(plain))
        #expect(String(data: sealed, encoding: .utf8)!.contains("owner_key") == false)
        #expect(try EncryptedBackup.decrypt(sealed, password: "correct horse battery") == plain)
        #expect(throws: EncryptedBackup.BackupError.wrongPassword) { try EncryptedBackup.decrypt(sealed, password: "wrong horse battery") }
        #expect(throws: EncryptedBackup.BackupError.passwordTooShort) {
            try EncryptedBackup.encrypt(airGesturesJSON: plain, password: "short", bandName: nil, fingerprint: nil)
        }
    }

    @Test func addressValidation() {
        #expect(AirGesturesBand.isValidAddress("A4:0E:2B:90:A6:64"))
        #expect(!AirGesturesBand.isValidAddress("A4:0E:2B:90:A6"))
        #expect(!AirGesturesBand.isValidAddress(UUID().uuidString))
        #expect(AirGesturesBand.isPrivateAddress("74:96:B7:84:FA:40"))
        #expect(!AirGesturesBand.isPrivateAddress("A4:0E:2B:90:A6:64"))
    }
}
