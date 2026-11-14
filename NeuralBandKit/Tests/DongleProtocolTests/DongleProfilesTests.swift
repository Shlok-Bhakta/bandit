import Foundation
import Testing
@testable import DongleProtocol

/// The shared vectors in firmware/np-profiles/tests: the dongle's checker (Rust) and this one
/// must agree on every file, down to the error path.
enum ProfileVectors {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("firmware/np-profiles")

    static func files(_ directory: String) throws -> [(name: String, data: Data)] {
        let folder = root.appendingPathComponent("tests/\(directory)")
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".json") }.sorted()
        return try names.map { ($0, try Data(contentsOf: folder.appendingPathComponent($0))) }
    }

    static func expectedPaths() throws -> [String: String] {
        let text = try String(contentsOf: root.appendingPathComponent("tests/invalid/expected.tsv"), encoding: .utf8)
        var paths: [String: String] = [:]
        for line in text.split(separator: "\n") where !line.isEmpty {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            paths[String(fields[0])] = fields.count > 1 ? String(fields[1]) : ""
        }
        return paths
    }

    static var defaultFile: Data {
        get throws { try Data(contentsOf: root.appendingPathComponent("profiles/default.json")) }
    }
}

@Suite struct ProfileVectorTests {
    @Test func everyValidVectorPasses() throws {
        let files = try ProfileVectors.files("valid")
        #expect(files.count >= 2)
        for file in files {
            #expect(ProfileFormat.validate(file.data) == nil, "\(file.name)")
            let set = try GestureProfileSet.decode(file.data)
            #expect(set.validate() == nil, "\(file.name) after the app reads and writes it")
        }
    }

    @Test func everyInvalidVectorFailsWhereExpected() throws {
        let files = try ProfileVectors.files("invalid")
        let expected = try ProfileVectors.expectedPaths()
        #expect(files.count == expected.count, "every invalid vector has an expected path")
        for file in files {
            let error = try #require(ProfileFormat.validate(file.data), "\(file.name) must be refused")
            #expect(error.path == expected[file.name], "\(file.name): \(error)")
        }
    }

    @Test func theEmbeddedDefaultIsTheFirmwaresDefault() throws {
        let file = try GestureProfileSet.decode(ProfileVectors.defaultFile)
        #expect(GestureProfileSet.builtin == file)
        #expect(GestureProfileSet.builtin.minifiedData == file.minifiedData)
        #expect(try JSONValue.parse(ProfileVectors.defaultFile) == JSONValue.parse(GestureProfileSet.builtinJSON))
        #expect(GestureProfileSet.builtin.validate() == nil)
    }

    @Test func theBuiltInSetDoesWhatTheDongleDid() throws {
        let set = try GestureProfileSet.builtin.parsed()
        #expect(set.profiles.map(\.id) == ["media", "slides", "write", "copilot", "tv"])
        let media = set.profiles[0]
        #expect(media.action(.middleDoubleTap, for: .phone) == .phoneMute)
        #expect(media.action(.middleDoubleTap, for: .windows) == .key(Chord(modifiers: Chord.gui | Chord.shift, usage: 0x10)))
        #expect(media.action(.indexHold, for: .mac) == .menu)
        #expect(media.action(.swipeUp, for: .mac) == nil)
        let write = set.profiles[2]
        #expect(write.action(.swipeDown, for: .mac) == .scroll(-4))
        let copilot = set.profiles[3]
        #expect(copilot.action(.middleHold, for: .mac) == .hold(Chord(modifiers: Chord.alt, usage: 0x2C)))
        #expect(copilot.action(.swipeRight, for: .mac) == .key(Chord(modifiers: Chord.gui | Chord.shift, usage: 0x30)))
        #expect(copilot.action(.swipeUp, for: .mac) == .key(Chord(modifiers: Chord.gui, usage: 0x34)))
        #expect(set.startProfile(for: .tv) == "tv")
        #expect(set.startProfile(for: .phone) == "media")
        #expect(set.menu["w"] == .profile(.id("write")))
        #expect(set.menu["l"] == .host(.next))
        #expect(!set.profiles[1].allows(.phone))
    }

    @Test func theEverythingVectorResolvesByHost() throws {
        let data = try #require(try ProfileVectors.files("valid").first { $0.name == "everything.json" }?.data)
        let set = try ProfileFormat.check(data)
        let music = set.profiles[0]
        #expect(music.action(.middleHold, for: .phone) == .media(.voice))
        #expect(music.action(.middleHold, for: .windows) == .hold(Chord(modifiers: Chord.alt, usage: 0x2C)))
        #expect(music.action(.middleHold, for: .mac) == .hold(Chord(modifiers: Chord.gui | Chord.shift, usage: 0x2C)))
        #expect(music.action(.middleHold, for: .tv) == nil)
        #expect(music.action(.middleTripleTap, for: .mac) == nil)
        let desk = set.profiles[1]
        #expect(desk.action(.swipeUp, for: .mac) == .scroll(10))
        #expect(desk.action(.middleTap, for: .mac) == .key(Chord(modifiers: Chord.gui | Chord.shift, usage: 0x2E)))
        #expect(desk.action(.indexTap, for: .mac) == .key(Chord(modifiers: 0, usage: 0x45)))
        #expect(set.startProfile(for: .linux) == "desk")
        #expect(set.menu["5"] == .type("hello"))
    }
}

@Suite struct ProfileCheckerTests {
    @Test func aBindingPicksTheMostSpecificHostKind() {
        let binding = GestureBinding.byHost(["computer": "key:enter", "mac": "key:cmd+enter", "default": "media:mute"])
        #expect(binding.action(for: .mac) == "key:cmd+enter")
        #expect(binding.action(for: .windows) == "key:enter")
        #expect(binding.action(for: .phone) == "media:mute")
        #expect(GestureBinding.action("menu").action(for: .tv) == "menu")
    }

    @Test func theDonglesSetIsReadBackFromItsLog() throws {
        let data = GestureProfileSet.builtin.minifiedData
        let sha8 = ProfileFormat.sha8(data)
        var dump = ProfileDump()
        dump.feed("12.000 I PROFILES: show begin \(data.count) \(sha8)")
        // Out of order, with other log lines between.
        let chunks = stride(from: 0, to: data.count, by: 150).map { ($0, data.subdata(in: $0..<min($0 + 150, data.count))) }
        for (offset, chunk) in chunks.reversed() {
            dump.feed("12.040 I PROFILES: show data \(offset) \(chunk.base64EncodedString())")
            dump.feed("12.041 I gesture #4: index tap")
        }
        #expect(dump.result == nil)
        dump.feed("12.900 I PROFILES: show end")
        #expect(try dump.result?.get() == ProfileDump.File(data: data, sha8: sha8, builtin: false))

        var short = ProfileDump()
        short.feed("PROFILES: show begin \(data.count) \(sha8) builtin")
        short.feed("PROFILES: show data 0 \(chunks[0].1.base64EncodedString())")
        short.feed("PROFILES: show end")
        #expect(throws: ProfileError.self) { try short.result?.get() }
    }

    @Test func chords() throws {
        #expect(try ProfileFormat.parseChord("cmd+shift+]").get() == Chord(modifiers: Chord.gui | Chord.shift, usage: 0x30))
        #expect(try ProfileFormat.parseChord("ctrl+alt+delete").get() == Chord(modifiers: Chord.ctrl | Chord.alt, usage: 0x4C))
        #expect(try ProfileFormat.parseChord("+").get() == Chord(modifiers: Chord.shift, usage: 0x2E))
        #expect(try ProfileFormat.parseChord("cmd++").get() == Chord(modifiers: Chord.gui | Chord.shift, usage: 0x2E))
        #expect(try ProfileFormat.parseChord("Option+F5").get() == Chord(modifiers: Chord.alt, usage: 0x3E))
        #expect(try ProfileFormat.parseChord("A").get() == Chord(modifiers: Chord.shift, usage: 0x04))
        for bad in ["", "cmd+", "hyper+a", "f13", "cmd++a", "é"] {
            #expect((try? ProfileFormat.parseChord(bad).get()) == nil, "\(bad)")
        }
    }

    @Test func actions() throws {
        let ids = ["a", "b"]
        func parse(_ text: String) throws -> ProfileAction { try ProfileFormat.parseAction(text, ids: ids, path: "x") }
        #expect(try parse("none") == ProfileAction.none)
        #expect(try parse("none:") == ProfileAction.none)
        #expect(try parse("mouse:scrollDown:+3") == .scroll(-3))
        #expect(try parse("mouse:rightClick") == .click(.right))
        #expect(try parse("type:a:b") == .type("a:b"))
        #expect(try parse("profile:b") == .profile(.id("b")))
        #expect(try parse("host:tv") == .host(.kind(.tv)))
        for bad in ["mouse:click:3", "mouse:scrollUp:21", "type:", "type:héllo", "profile:c", "host:fridge", "media:loud", "Menu", "menu:x"] {
            #expect(throws: ProfileError.self, "\(bad)") { try parse(bad) }
        }
        let error = try #require(ProfileFormat.validate(Data(#"{"format":"np-profiles","version":1,"profiles":[{"id":"a","name":"A","gestures":{"swipe.up":7}}]}"#.utf8)))
        #expect(error.path == "profiles[0].gestures.swipe.up")
    }

    @Test func typeErrorsAreTheWholeFile() throws {
        for text in [#"{"format":"np-profiles","version":1.0,"profiles":[{"id":"a","name":"A"}]}"#,
                     #"{"format":"np-profiles","version":1,"name":null,"profiles":[{"id":"a","name":"A"}]}"#,
                     #"{"format":"np-profiles","version":1,"profiles":[{"id":"a"}]}"#,
                     #"[1]"#, "not json", #"{"format":"np-profiles","version":1,"profiles":[]} x"#] {
            let error = try #require(ProfileFormat.validate(Data(text.utf8)), "\(text)")
            #expect(error.path == "", "\(text): \(error)")
        }
    }

    @Test func numericBuzzErrorsHaveAFieldPath() {
        for value in ["0", "5", "300", "-1", "1.5", "1.0"] {
            let data = Data("{\"format\":\"np-profiles\",\"version\":1,\"profiles\":[{\"id\":\"a\",\"name\":\"A\",\"buzz\":\(value)}]}".utf8)
            #expect(ProfileFormat.validate(data) == ProfileError("profiles[0].buzz", "1–4 buzzes"))
        }
    }

    @Test func startNeedsEveryComputer() throws {
        let text = #"{"format":"np-profiles","version":1,"profiles":[{"id":"m","name":"Mac only","hosts":["mac","phone","tv"]}]}"#
        #expect(ProfileFormat.validate(Data(text.utf8))?.path == "start.computer")
        let extra = #"{"format":"np-profiles","version":1,"start":{"watch":"a"},"profiles":[{"id":"a","name":"A"}]}"#
        #expect(ProfileFormat.validate(Data(extra.utf8))?.path == "start.watch")
    }

    @Test func filesOverTheLimitAreRefused() throws {
        var set = GestureProfileSet.builtin
        set.profiles[0].description = String(repeating: "x", count: ProfileFormat.maxBytes)
        let error = try #require(set.validate())
        #expect(error.path == "" && error.message.contains("too big"))
        #expect(throws: ProfileError.self) { try ProfileUpload(set.minifiedData) }
    }
}

@Suite struct ProfileFileTests {
    @Test func roundTripsAndKeepsUnknownFields() throws {
        let text = """
        {"format":"np-profiles","version":1,"name":"Mine","x-app":{"theme":[1,2.5,null,true,"é\\n"]},
         "profiles":[{"id":"a","name":"A","symbol":"music.note","color":"#33ddaa","description":"d","future":{"k":1},
           "gestures":{"index.doubleTap":"media:playPause","middle.hold":{"mac":"hold:cmd+space","default":"media:voice"}}}]}
        """
        let set = try GestureProfileSet.decode(Data(text.utf8))
        #expect(set.validate() == nil)
        #expect(set.profiles[0].symbol == "music.note")
        #expect(set.profiles[0].color == "#33ddaa")
        #expect(set.profiles[0].extra["future"] == .object(JSONObject([.init("k", .integer(1))])))
        #expect(set.extra["x-app"] != nil)
        let again = try GestureProfileSet.decode(set.minifiedData)
        #expect(again == set)
        #expect(try GestureProfileSet.decode(set.prettyData) == set)
        #expect(again.minifiedData == set.minifiedData)
        #expect(!set.json.minified.contains(" "))
        #expect(try JSONValue.parse(set.prettyData) == set.json)
    }

    @Test func everyVectorRoundTrips() throws {
        for file in try ProfileVectors.files("valid") + ProfileVectors.files("invalid") {
            guard let set = try? GestureProfileSet.decode(file.data) else { continue }
            #expect(try GestureProfileSet.decode(set.prettyData) == set, "\(file.name)")
            #expect(set.validate()?.path == ProfileFormat.validate(file.data)?.path, "\(file.name)")
        }
    }

    @Test func stableOrderAndHash() throws {
        let set = GestureProfileSet.builtin
        let minified = String(decoding: set.minifiedData, as: UTF8.self)
        #expect(minified.hasPrefix(#"{"format":"np-profiles","version":1,"name":"Built-in","menu":{"c":"profile:copilot""#))
        #expect(set.sha8.count == 8 && set.sha8.allSatisfy(\.isHexDigit) && set.sha8 == set.sha8.lowercased())
        #expect(ProfileFormat.sha8(Data("abc".utf8)) == "ba7816bf")
        var edited = set
        edited.profiles[0].name = "Music"
        #expect(edited.sha8 != set.sha8)
    }

    @Test func bindings() {
        #expect(GestureBinding.make(default: "menu", overrides: [:]) == .action("menu"))
        #expect(GestureBinding.make(default: nil, overrides: [:]) == nil)
        let binding = GestureBinding.make(default: "media:mute", overrides: ["phone": "phoneMute"])
        #expect(binding == .byHost(["phone": "phoneMute", "default": "media:mute"]))
        #expect(binding?.overrides == ["phone": "phoneMute"])
        #expect(binding?.json.minified == #"{"phone":"phoneMute","default":"media:mute"}"#)
    }

    @Test func unusedIDs() {
        let set = GestureProfileSet.builtin
        #expect(set.unusedID("Media") == "media-2")
        #expect(set.unusedID("My Set!") == "myset")
        #expect(set.unusedID("") == "custom")
    }

    @Test func extractsJSONFromPastedAnswers() {
        let answer = "Sure! Here it is:\n```json\n{\"a\": {\"b\": 1}}\n```\nEnjoy."
        #expect(ProfileFormat.extractJSON(from: answer) == "{\"a\": {\"b\": 1}}")
        #expect(ProfileFormat.extractJSON(from: "here {\"x\":1} done") == "{\"x\":1}")
        #expect(ProfileFormat.extractJSON(from: "  plain  ") == "plain")
    }

    @Test func briefNamesEveryGesture() {
        let brief = ProfileFormat.assistantBrief
        for gesture in ProfileGesture.allCases { #expect(brief.contains("`\(gesture.rawValue)`")) }
    }
}

@Suite struct ProfileUploadTests {
    @Test func chunksFitOneCommandAndReassemble() throws {
        var set = GestureProfileSet.builtin
        set.profiles[0].description = String(repeating: "é", count: 600)
        let data = set.minifiedData
        #expect(data.count > 2000 && data.count <= ProfileFormat.maxBytes)
        let upload = try ProfileUpload(data)
        let commands = upload.commands
        #expect(commands.first == .profilesBegin(bytes: data.count, sha8: ProfileFormat.sha8(data)))
        #expect(commands.last == .profilesCommit)
        var reassembled = Data()
        for command in commands {
            #expect(command.data.count <= ProfileUpload.maxCommandBytes, "\(command.text.prefix(40))")
            guard case .profilesData(let offset, let chunk) = command else { continue }
            #expect(offset == reassembled.count)
            let parts = command.text.split(separator: " ")
            #expect(parts.count == 4 && parts[0] == "profiles" && parts[1] == "data" && Int(parts[2]) == offset)
            reassembled += try #require(Data(base64Encoded: String(parts[3])))
            #expect(chunk.count <= ProfileUpload.chunkSize)
        }
        #expect(reassembled == data)
        #expect(commands.first?.text == "profiles begin \(data.count) \(upload.sha8)")
    }

    @Test func theLargestFileStillFits() throws {
        let data = Data(repeating: 0x41, count: ProfileFormat.maxBytes)
        for command in try ProfileUpload(data).commands { #expect(command.data.count <= ProfileUpload.maxCommandBytes) }
        #expect(throws: ProfileError.self) { try ProfileUpload(data + Data([0x41])) }
    }

    @Test func profileCommands() {
        #expect(DongleCommand.profile("write").text == "profile write")
        #expect(DongleCommand.profileNext.text == "profile next")
        #expect(DongleCommand.profilePrevious.text == "profile previous")
        #expect(DongleCommand.hostProfile(3, "tv").text == "profile 3 tv")
        #expect(DongleCommand.profilesReset.text == "profiles reset")
        #expect(DongleCommand.profilesData(offset: 150, Data([1, 2, 3])).text == "profiles data 150 AQID")
    }
}

@Suite struct DongleStatusProfileTests {
    @Test func decodesProfileFields() throws {
        let json = #"{"mode":"desk","ph":"3FA2C1D0","pe":"profiles[0].id: bad","hosts":[{"h":1,"k":"computer","n":"Mac","act":true,"p":"desk"},{"h":2,"k":"phone"}]}"#
        let status = try DongleStatus.decode(Data(json.utf8))
        #expect(status.mode == "desk")
        #expect(status.profileHash == "3fa2c1d0")
        #expect(status.profileError == "profiles[0].id: bad")
        #expect(status.hosts[0].profile == "desk")
        #expect(status.hosts[1].profile == nil)
        #expect(status.supportsProfiles)
    }

    @Test func olderFirmwareHasNoProfiles() throws {
        let status = try DongleStatus.decode(Data(#"{"mode":"slides","pe":""}"#.utf8))
        #expect(status.profileHash == nil && status.profileError == nil && !status.supportsProfiles)
    }
}

@Suite struct BuzzAndLabTests {
    @Test func catalogCoversEveryBandEvent() throws {
        #expect(ProfileGesture.named.count == 18)
        #expect(ProfileGesture.band.count == 120)
        #expect(Set(ProfileGesture.allCases).count == 138)
        for gesture in ProfileGesture.allCases {
            #expect(ProfileGesture(rawValue: gesture.rawValue) == gesture)
            var set = GestureProfileSet(profiles: [GestureProfile(id: "a", name: "A")])
            set.profiles[0][gesture] = .action("apps:next")
            #expect(set.validate() == nil)
            #expect(try GestureProfileSet.decode(set.minifiedData).profiles[0][gesture] == .action("apps:next"))
        }
        for name in ["band.unknown", "band.ring.click", "band.thumb.click.extra", "flick.diagonal"] { #expect(ProfileGesture(rawValue: name) == nil) }
    }
    @Test func patternsFollowTheFirmwareGrammar() throws {
        let pattern = try ProfileFormat.parsePattern("250 _200 250*90")
        #expect(pattern.duration == 700)
        #expect(pattern.pulses.map(\.atMS) == [0, 450])
        #expect(pattern.pulses.map(\.strength) == [70, 90])
        for builtin in ProfileFormat.builtinBuzzes { #expect(try ProfileFormat.parsePattern(builtin.text).duration > 0) }
        for (text, message) in [
            ("_20 30", "a pause goes between two pulses"),
            ("20 _20", "a pattern ends with a pulse"),
            ("20 _20 _20 20", "a pause goes between two pulses"),
            ("19", "a pulse is 20–2000 ms"),
            ("20*0", "strength is 1–100"),
            ("20 _3001 20", "a pause is 20–3000 ms"),
            ("2000 2000 2000 2000 20", "a pattern lasts at most 8000 ms")
        ] {
            do { _ = try ProfileFormat.parsePattern(text); Issue.record("Accepted \(text)") }
            catch let error as ProfileError { #expect(error.message == message) }
        }
    }
    @Test func redefinedPatternsResolveEverywhereAndRoundTrip() throws {
        let data = Data(#"{"format":"np-profiles","version":1,"custom":{"keep":true},"buzzes":{"tap":"80*22","zap":"50 _100 80*90"},"feedback":{"connected":"none","gesture":"zap"},"profiles":[{"id":"a","name":"A","buzz":"zap","gestures":{"flick.up":{"default":"buzz:zap","buzz":"tap"},"band.thumb.click":"apps:previous"}}]}"#.utf8)
        let editable = try GestureProfileSet.decode(data)
        let parsed = try editable.parsed()
        #expect(parsed.feedback["connected"] == nil)
        #expect(parsed.profiles[0].buzz == parsed.buzzes["zap"])
        #expect(parsed.profiles[0].gestures[.flickUp]?.buzz == parsed.buzzes["tap"])
        #expect(parsed.profiles[0].gestures[.flickUp]?.defaultAction == .buzz(parsed.buzzes["zap"]!))
        #expect(editable.profiles[0].copy(id: "b", name: "B").buzzName == "zap")
        #expect(try GestureProfileSet.decode(editable.minifiedData) == editable)
        #expect(editable.extra["custom"] != nil)
        #expect(DongleCommand.buzz("tap").text == "buzz tap")
        #expect(DongleCommand.buzzTry("50 _100 80*90").text == "buzz try 50 _100 80*90")
        #expect(DongleCommand.lab(true).text == "lab on")
    }
    @Test func logRecordsKeepUnknownValuesAndMapEvents() {
        #expect(GestureLabRecord.parse("12.345 I gesture #812: index tap singleTap") == .message(sequence: 812, finger: "index", action: "tap", derived: "singleTap"))
        #expect(GestureLabRecord.parse("1.000 I gesture #9: unknown unrecognized:42 notApplicable") == .message(sequence: 9, finger: "unknown", action: "unrecognized:42", derived: "notApplicable"))
        #expect(GestureLabRecord.parse("1 I LAB flick up 220 °/s") == .motion(flick: true, direction: "up", peak: "220 °/s"))
        #expect(GestureLabRecord.parse("1 I LAB swing left 100 °/s") == .motion(flick: false, direction: "left", peak: "100 °/s"))
        #expect(GestureLabRecord.parse("1 I GESTURE: flick.up in media: Apps(true)") == .fired(gesture: "flick.up", profile: "media", action: "Apps(true)"))
        #expect(GestureLabRecord.parse("1 I LAB fields thumb right buttonRight: pressure: 4") == .fields("thumb right buttonRight: pressure: 4"))
        #expect(GestureLabRecord.bandNames(finger: "thumb", action: "click", derived: "click") == ["band.thumb.click", "band.click"])
        #expect(GestureLabRecord.bandNames(finger: "unknown", action: "click", derived: "notApplicable") == ["band.click"])
        #expect(GestureLabRecord.parse("not a gesture") == nil)
    }
}
