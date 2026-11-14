import Testing
@testable import BandAccessibility
import BandProtocol

@Suite struct BCIDescriptorTests {
    @Test func descriptorMatchesAppleStructure() {
        let d = BCIHID.descriptor
        #expect(d.prefix(6) == [0x05, 0x60, 0x09, 0x01, 0xA1, 0x01], "BCI usage page 0x60, application collection")
        #expect(d.last == 0xC0)
        #expect(d.count == 119, "Apple's descriptor is 119 bytes")
        let items = try! BCIHID.items(d)
        // Collections balance (Collection 0xA0 / End Collection 0xC0).
        #expect(items.filter { $0.tag == 0xA0 }.count == items.filter { $0.tag == 0xC0 }.count)
        // Report IDs 1, 2, 3 and two report-4 items (input + output).
        #expect(items.filter { $0.tag == 0x84 }.map { $0.data[0] } == [1, 2, 3, 4, 4])
        // Four inputs and one constant 6-byte output.
        #expect(items.filter { $0.tag == 0x80 }.count == 4)
        #expect(items.filter { $0.tag == 0x90 }.map(\.data) == [[0x03]])
        // Pointer logical range -127...127 keeps -128 reserved.
        #expect(items.contains { $0.tag == 0x14 && $0.data == [0x81] })
        // 32 one-bit buttons.
        #expect(items.contains { $0.tag == 0x94 && $0.data == [0x20] } && items.contains { $0.tag == 0x74 && $0.data == [0x01] })
    }

    @Test func absoluteVariantChangesOnlyThePointerFlag() {
        let relative = BCIHID.descriptor
        let absolute = BCIHID.absolutePointerDescriptor
        let differing = relative.indices.filter { relative[$0] != absolute[$0] }
        #expect(differing == [BCIHID.pointerInputFlagsOffset])
        #expect(relative[BCIHID.pointerInputFlagsOffset - 1] == 0x81)
        #expect(relative[BCIHID.pointerInputFlagsOffset] == 0x06 && absolute[BCIHID.pointerInputFlagsOffset] == 0x02)
    }
}

@Suite struct DescriptorParserTests {
    @Test func truncatedDescriptorsAreRejected() {
        #expect(throws: BCIError.self) { try BCIHID.items([0x26, 0xFF]) }
        #expect(throws: BCIError.self) { try BCIHID.items([0xFE, 0x01]) }
    }
}

@Suite struct BCIButtonTests {
    @Test func bitPositionsFollowApplesByteAndMaskRule() throws {
        var state = BCIButtonState()
        #expect(try state.press(0).payload == [0x01, 0, 0, 0])
        #expect(try state.press(9).payload == [0x01, 0x02, 0, 0])
        #expect(try state.press(31).payload == [0x01, 0x02, 0, 0x80])
        #expect(state.report.bytes.first == 2, "report ID 2 first when prefixed")
    }

    @Test func releasePreservesOtherButtons() throws {
        var state = BCIButtonState()
        _ = try state.press(BCIAction.select.buttonIndex)
        let reports = try state.click(BCIAction.volumeUp.buttonIndex)
        #expect(reports.count == 2)
        #expect(reports[0].payload == [0x01, 0x20, 0, 0], "volume up (13) pressed with select still down")
        #expect(reports[1].payload == [0x01, 0, 0, 0], "volume up released, select kept")
        #expect(state.pressedButtons == [0])
        #expect(state.releaseAll().payload == [0, 0, 0, 0])
        #expect(state.pressedButtons.isEmpty)
    }

    @Test func invalidButtonsAreRejected() {
        var state = BCIButtonState()
        #expect(throws: BCIError.invalidButton(32)) { try state.press(32) }
        #expect(throws: BCIError.invalidButton(-1)) { try state.release(-1) }
        #expect(state.bits == 0)
    }

    @Test func documentedIndices() {
        #expect(BCIAction.select.buttonIndex == 0)
        #expect(BCIAction.moveToNextItem.buttonIndex == 1)
        #expect(BCIAction.moveToPreviousItem.buttonIndex == 2)
        #expect(BCIAction.toggleAssistiveTechnologyMenu.buttonIndex == 3)
        #expect(BCIAction.allCases.count == 22)
        #expect(BCIAction.scrollRight.buttonIndex == 21)
    }
}

@Suite struct BCIPointerTests {
    @Test func dimensionalityUsesTheAbsentSentinel() throws {
        #expect(try BCIReport.pointer(x: 5).payload == [5, 0x80, 0x80])
        #expect(try BCIReport.pointer(x: -5, y: 3).payload == [0xFB, 3, 0x80])
        #expect(try BCIReport.pointer(x: 0, y: 0, z: 0).payload == [0, 0, 0], "0 is a real 'no movement' value")
    }

    @Test func realValuesNeverBecomeTheSentinel() throws {
        #expect(try BCIReport.pointer(x: -500, y: 500).payload == [0x81, 0x7F, 0x80], "clamped to -127 / 127")
        #expect(try BCIReport.pointer(x: -128).payload[0] == 0x81)
    }

    @Test func invalidShapesAreRejected() {
        #expect(throws: BCIError.pointerXAbsent) { try BCIReport.pointer(x: nil, y: 4) }
        #expect(throws: BCIError.invalidPointerShape) { try BCIReport.pointer(x: 1, y: nil, z: 2) }
    }
}

@Suite struct BCIOtherReportTests {
    @Test func signalQualityScalesPercent() {
        #expect(BCIReport.signalQuality(button: 0, strengthPercent: 100).payload == [0, 255])
        #expect(BCIReport.signalQuality(button: 2, strengthPercent: 50).payload == [2, 127])
        #expect(BCIReport.signalQuality(button: 0, strengthPercent: 150).payload == [0, 255])
    }

    @Test func scanInfoParsesWithAndWithoutReportID() throws {
        let info = try BCIScanInfo([3, 12, 7, 1, 0, 128])
        #expect(info.selectedItem == 3 && info.numberOfItems == 12 && info.seed == 7 && info.itemControlType == 1)
        #expect(abs(info.latencySeconds - 128.0 / 255) < 1e-9)
        #expect(try BCIScanInfo([4, 3, 12, 7, 0, 1, 0]).latencySeconds == 1)
        #expect(throws: BCIError.self) { try BCIScanInfo([1, 2, 3]) }
        #expect(throws: BCIError.self) { try BCIScanInfo([9, 3, 12, 7, 0, 1, 0]) }
    }

    @Test func itemSelection() {
        #expect(BCIReport.itemSelection(42).bytes == [4, 42])
    }
}

@Suite struct IntentTests {
    @Test func defaultMappingClicksWithoutStickingButtons() {
        var encoder = IntentEncoder()
        let result = encoder.reports(for: .tap(.index, .tap), mapping: .default)
        #expect(result?.action == .select)
        #expect(result?.reports.map(\.payload) == [[1, 0, 0, 0], [0, 0, 0, 0]])
        #expect(encoder.state.pressedButtons.isEmpty)
        #expect(encoder.reports(for: .swipe(.right), mapping: .default)?.action == .moveToNextItem)
        #expect(encoder.reports(for: .tap(.index, .hold), mapping: .default) == nil, "unmapped gestures send nothing")
    }

    @Test func holdsPressAndReleaseSeparately() {
        var encoder = IntentEncoder()
        #expect(encoder.pressReport(.scrollDown)?.payload == [0, 0, 0x08, 0])
        #expect(encoder.state.pressedButtons == [19])
        #expect(encoder.releaseAll().payload == [0, 0, 0, 0])
    }
}
