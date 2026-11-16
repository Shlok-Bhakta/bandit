import Foundation
import Testing
@testable import DongleProtocol

@Suite struct ProfileMergeTests {
    private func set(_ ids: [String], menu: [String: String] = [:]) -> GestureProfileSet {
        GestureProfileSet(name: "Test", menu: menu, profiles: ids.map { GestureProfile(id: $0, name: $0.capitalized) })
    }

    @Test func differencesNameEachChangedPart() {
        let a = set(["media", "slides"], menu: ["m": "profile:media"])
        var b = a
        b.profiles[1].name = "Talks"
        b.menu["s"] = "profile:slides"
        #expect(a.differences(from: b) == [.menu, .profile("slides")])
        #expect(a.differences(from: a).isEmpty)
    }

    @Test func oneSidedChangesMergeWithoutConflicts() {
        let base = set(["media", "slides"])
        var phone = base
        phone.profiles[0].name = "Home"
        var dongle = base
        dongle.menu["s"] = "profile:slides"
        dongle.profiles.append(GestureProfile(id: "copilot", name: "Copilot"))
        let merge = ProfileMerge(base: base, phone: phone, other: dongle)
        #expect(merge.conflicts.isEmpty)
        let result = merge.result
        #expect(result.profile(id: "media")?.name == "Home")
        #expect(result.menu["s"] == "profile:slides")
        #expect(result.ids == ["media", "slides", "copilot"])
    }

    @Test func bothSidesChangingAPartIsAConflict() {
        let base = set(["media"])
        var phone = base
        phone.profiles[0].name = "Phone"
        var dongle = base
        dongle.profiles[0].name = "Dongle"
        var merge = ProfileMerge(base: base, phone: phone, other: dongle)
        #expect(merge.conflicts.map(\.part) == [.profile("media")])
        #expect(merge.result.profiles[0].name == "Phone")
        merge.pickAll(.other)
        #expect(merge.result.profiles[0].name == "Dongle")
        // The phone's profile keeps its identity, so an open editor stays on it.
        #expect(merge.result.profiles[0].uid == phone.profiles[0].uid)
    }

    @Test func withoutABaseEveryDifferenceIsAConflict() {
        let phone = set(["media"])
        let file = set(["media", "tv"])
        let merge = ProfileMerge(base: nil, phone: phone, other: file, prefer: .other)
        #expect(merge.items.allSatisfy { $0.change == .both })
        #expect(merge.result.ids == ["media", "tv"])
    }

    @Test func deletionOnOneSideCarriesOver() {
        let base = set(["media", "slides", "tv"])
        var dongle = base
        dongle.profiles.remove(at: 1)
        let merge = ProfileMerge(base: base, phone: base, other: dongle)
        #expect(merge.result.ids == ["media", "tv"])
    }

    @Test func addingOnBothSidesIsNotAnOrderConflict() {
        let base = set(["a", "b"])
        let phone = set(["a", "b", "x"])
        let dongle = set(["a", "y", "b"])
        let merge = ProfileMerge(base: base, phone: phone, other: dongle)
        #expect(merge.conflicts.isEmpty)
        #expect(merge.result.ids == ["a", "y", "b", "x"])
    }

    @Test func reorderingTakesTheOtherSidesOrder() {
        let base = set(["a", "b", "c"])
        let dongle = set(["c", "a", "b"])
        let phone = set(["a", "b", "c", "x"])
        let merge = ProfileMerge(base: base, phone: phone, other: dongle)
        #expect(merge.items.first { $0.part == .order }?.change == .other)
        #expect(merge.result.ids == ["c", "a", "b", "x"])
    }

    @Test func replacingAPartRevertsJustThatPart() {
        let dongle = set(["media", "slides"], menu: ["m": "profile:media"])
        var phone = dongle
        phone.profiles[0].name = "Home"
        phone.menu = [:]
        let reverted = phone.replacing(.menu, from: dongle)
        #expect(reverted.menu == dongle.menu)
        #expect(reverted.profiles[0].name == "Home")
        #expect(reverted.differences(from: dongle) == [.profile("media")])
    }
}
