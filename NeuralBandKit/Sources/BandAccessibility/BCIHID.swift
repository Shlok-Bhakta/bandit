import Foundation

/// Apple's Brain-Computer Interface HID reference ("Brain-computer interface HID reference for
/// connecting to Apple platforms", developer.apple.com, fetched 2026-11-10).
///
/// The Neural Band measures surface EMG (muscle activity), not brain activity. This module only
/// uses the BCI HID *interface* to deliver muscle-derived user intent to Apple's assistive
/// technology (Switch Control, AssistiveTouch); nothing here measures or claims neural signals.
public enum BCIHID {
    public enum ReportID: UInt8, Sendable {
        case signalQuality = 1
        case buttons = 2
        case pointer = 3
        /// Input: item selection. Output (host → device): scan information.
        case item = 4
    }

    /// Apple's example descriptor, byte for byte. Pointer item is Relative (`0x81 0x06`) by default.
    public static let descriptor: [UInt8] = [
        0x05, 0x60, 0x09, 0x01, 0xA1, 0x01,                         // BCI page, BCI Application, Collection (Application)
        // Report 1: signal quality (decorator)
        0x05, 0x60, 0x09, 0x02, 0x85, 0x01, 0xA1, 0x02,
        0x09, 0x02, 0x15, 0x00, 0x26, 0xFF, 0x00, 0x75, 0x08, 0x95, 0x02, 0x81, 0x06,
        0xC0,
        // Report 2: 32 buttons
        0x05, 0x09, 0x09, 0x01, 0x85, 0x02, 0xA1, 0x00,
        0x19, 0x01, 0x29, 0x20, 0x15, 0x00, 0x25, 0x01, 0x75, 0x01, 0x95, 0x20, 0x81, 0x02,
        0xC0,
        // Report 3: pointer x/y/z, logical -127...127 (-128 reserved as "axis absent")
        0x05, 0x01, 0x09, 0x01, 0x85, 0x03, 0xA1, 0x00,
        0x09, 0x30, 0x09, 0x31, 0x09, 0x32, 0x15, 0x81, 0x25, 0x7F, 0x75, 0x08, 0x95, 0x03, 0x81, 0x06,
        0xC0,
        // Report 4 (input): item selection
        0x05, 0x60, 0x09, 0x04, 0x85, 0x04, 0xA1, 0x02,
        0x09, 0x04, 0x15, 0x00, 0x26, 0xFF, 0x00, 0x75, 0x08, 0x95, 0x01, 0x81, 0x06,
        0xC0,
        // Report 4 (output): scan information, 6 bytes
        0x05, 0x60, 0xA1, 0x02, 0x85, 0x04,
        0x09, 0x03, 0x15, 0x00, 0x26, 0xFF, 0x00, 0x75, 0x08, 0x95, 0x06, 0x91, 0x03,
        0xC0,
        0xC0,
    ]

    /// One short HID item: its offset, prefix byte (tag/type/size) and data bytes.
    public struct Item: Equatable, Sendable {
        public let offset: Int
        public let prefix: UInt8
        public let data: [UInt8]
        /// The prefix without its size bits, e.g. `0x80` Input, `0x90` Output, `0x84` Report ID.
        public var tag: UInt8 { prefix & 0xFC }
    }

    /// Parses short items (sizes 0, 1, 2, 4). Long items aren't used by Apple's descriptor.
    public static func items(_ bytes: [UInt8]) throws -> [Item] {
        var items: [Item] = []
        var offset = 0
        while offset < bytes.count {
            let prefix = bytes[offset]
            guard prefix != 0xFE else { throw BCIError.malformedReport("long items unsupported") }
            let size = [0, 1, 2, 4][Int(prefix & 0x03)]
            guard offset + 1 + size <= bytes.count else { throw BCIError.malformedReport("truncated item at \(offset)") }
            items.append(Item(offset: offset, prefix: prefix, data: Array(bytes[(offset + 1)..<(offset + 1 + size)])))
            offset += 1 + size
        }
        return items
    }

    /// The byte offset of the pointer Input item's flags byte (`06` in `0x81 0x06` after Report ID 3).
    static let pointerInputFlagsOffset: Int = {
        let parsed = try! items(descriptor)
        let reportID3 = parsed.firstIndex { $0.tag == 0x84 && $0.data == [3] }!
        let input = parsed[reportID3...].first { $0.tag == 0x80 }!
        return input.offset + 1
    }()

    /// The descriptor with the pointer declared Absolute (`0x81 0x02`), the only change Apple allows.
    public static var absolutePointerDescriptor: [UInt8] {
        var bytes = descriptor
        bytes[pointerInputFlagsOffset] = 0x02
        return bytes
    }

    public static let pointerAxisAbsent: Int8 = -128
}

/// iOS button actions, in Apple's documented order (button index 0...21). Apple's descriptor
/// comment fixes 0–3 ("button 0 = select, 1 = next, 2 = previous, 3 = menu"); the rest follow the
/// order of Apple's action list and should be confirmed on a device.
public enum BCIAction: Int, CaseIterable, Codable, Sendable, Identifiable {
    case select = 0
    case moveToNextItem
    case moveToPreviousItem
    case toggleAssistiveTechnologyMenu
    case activate
    case startSequentialNavigation
    case stopSequentialNavigation
    case triggerAutomation
    case toggleAppSwitcher
    case home
    case toggleNotificationsView
    case assistant
    case volumeDown
    case volumeUp
    case toggleDictation
    case toggleAccessibilityFeature
    case toggleQuickSettingsView
    case escape
    case scrollUp
    case scrollDown
    case scrollLeft
    case scrollRight

    public var id: Int { rawValue }
    public var buttonIndex: Int { rawValue }
    /// Index fixed by Apple's descriptor comment (vs. inferred from list order).
    public var isDocumentedIndex: Bool { rawValue <= 3 }

    public var title: String {
        switch self {
        case .select: "Select"
        case .moveToNextItem: "Next item"
        case .moveToPreviousItem: "Previous item"
        case .toggleAssistiveTechnologyMenu: "Accessibility menu"
        case .activate: "Activate"
        case .startSequentialNavigation: "Start scanning"
        case .stopSequentialNavigation: "Stop scanning"
        case .triggerAutomation: "Trigger automation"
        case .toggleAppSwitcher: "App Switcher"
        case .home: "Home"
        case .toggleNotificationsView: "Notifications"
        case .assistant: "Siri"
        case .volumeDown: "Volume down"
        case .volumeUp: "Volume up"
        case .toggleDictation: "Dictation"
        case .toggleAccessibilityFeature: "Accessibility shortcut"
        case .toggleQuickSettingsView: "Control Center"
        case .escape: "Escape / back"
        case .scrollUp: "Scroll up"
        case .scrollDown: "Scroll down"
        case .scrollLeft: "Scroll left"
        case .scrollRight: "Scroll right"
        }
    }
}

public enum BCIError: Error, Equatable, Sendable {
    case invalidButton(Int)
    case pointerXAbsent
    case invalidPointerShape
    case malformedReport(String)
}

/// The absolute state of all 32 buttons (Report 2). Every report carries every button.
public struct BCIButtonState: Equatable, Sendable {
    public private(set) var bits: UInt32 = 0

    public init() {}

    public func isPressed(_ index: Int) -> Bool { index >= 0 && index < 32 && bits & (1 << UInt32(index)) != 0 }
    public var pressedButtons: [Int] { (0..<32).filter(isPressed) }

    /// Press one button, leaving the others as they are. Returns the report to send.
    public mutating func press(_ index: Int) throws -> BCIReport {
        guard (0..<32).contains(index) else { throw BCIError.invalidButton(index) }
        bits |= 1 << UInt32(index)
        return report
    }

    public mutating func release(_ index: Int) throws -> BCIReport {
        guard (0..<32).contains(index) else { throw BCIError.invalidButton(index) }
        bits &= ~(1 << UInt32(index))
        return report
    }

    /// Emergency stop: everything up.
    public mutating func releaseAll() -> BCIReport {
        bits = 0
        return report
    }

    /// Press then release one button (Apple's `send_bci_button_click`).
    public mutating func click(_ index: Int) throws -> [BCIReport] {
        [try press(index), try release(index)]
    }

    /// `buttons[byte] bit (index % 8)` for byte `index / 8`, little-endian across the 4 bytes.
    public var report: BCIReport {
        BCIReport(id: .buttons, payload: [UInt8(bits & 0xff), UInt8((bits >> 8) & 0xff), UInt8((bits >> 16) & 0xff), UInt8(bits >> 24)])
    }
}

/// One input report. BLE HID-over-GATT carries `payload` on a Report characteristic whose Report
/// Reference descriptor names the ID; USB and Apple's IOHIDUserDevice examples prefix the ID (`bytes`).
public struct BCIReport: Equatable, Sendable, CustomStringConvertible {
    public let id: BCIHID.ReportID
    public let payload: [UInt8]

    public var bytes: [UInt8] { [id.rawValue] + payload }
    public var description: String { "report \(id.rawValue): " + bytes.map { String(format: "%02X", $0) }.joined(separator: " ") }

    /// Report 3. `nil` axes are sent as the -128 sentinel; real values are clamped to -127...127.
    /// Valid shapes: x only (1D gliding cursor), x+y (2D pointer), x+y+z (3D). x must be present.
    public static func pointer(x: Int?, y: Int? = nil, z: Int? = nil) throws -> BCIReport {
        guard let x else { throw BCIError.pointerXAbsent }
        if y == nil, z != nil { throw BCIError.invalidPointerShape }
        func clamp(_ value: Int) -> UInt8 { UInt8(bitPattern: Int8(max(-127, min(127, value)))) }
        let absent = UInt8(bitPattern: BCIHID.pointerAxisAbsent)
        return BCIReport(id: .pointer, payload: [clamp(x), y.map(clamp) ?? absent, z.map(clamp) ?? absent])
    }

    /// Report 4 (input): ask the host to select item `index` from the current scan cycle.
    public static func itemSelection(_ index: UInt8) -> BCIReport { BCIReport(id: .item, payload: [index]) }

    /// Report 1. Only send with a validated measure; this app doesn't invent one.
    public static func signalQuality(button: UInt8, strengthPercent: Int) -> BCIReport {
        let percent = max(0, min(100, strengthPercent))
        return BCIReport(id: .signalQuality, payload: [button, UInt8(Double(percent) * 255 / 100)])
    }
}

/// Report 4 (output): what Switch Control is scanning.
public struct BCIScanInfo: Equatable, Sendable {
    public let selectedItem: UInt8
    public let numberOfItems: UInt8
    public let seed: UInt8
    /// 0 = discrete item, 1 = continuous control (scroll view, slider).
    public let itemControlType: UInt8
    public let latencySeconds: Double

    /// Accepts the 6-byte payload, or 7 bytes with a leading report ID 4.
    public init(_ bytes: [UInt8]) throws {
        var data = bytes
        if data.count == 7 {
            guard data[0] == BCIHID.ReportID.item.rawValue else { throw BCIError.malformedReport("unexpected report ID \(data[0])") }
            data.removeFirst()
        }
        guard data.count == 6 else { throw BCIError.malformedReport("scan info is \(bytes.count) bytes, expected 6") }
        selectedItem = data[0]
        numberOfItems = data[1]
        seed = data[2]
        itemControlType = data[3]
        latencySeconds = Double(data[4]) + Double(data[5]) / 255
    }
}
