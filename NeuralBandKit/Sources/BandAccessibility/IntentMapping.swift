import BandProtocol
import Foundation

/// What a normalized gesture should do. Per-wrist so a friend can switch profiles and test at once.
public struct IntentMapping: Codable, Equatable, Sendable {
    public var actions: [RecognizedGesture: BCIAction]

    public init(actions: [RecognizedGesture: BCIAction]) { self.actions = actions }

    /// A Switch Control friendly default: index tap selects, swipes step through items.
    public static let `default` = IntentMapping(actions: [
        .tap(.index, .tap): .select,
        .swipe(.right): .moveToNextItem,
        .swipe(.left): .moveToPreviousItem,
        .tap(.middle, .tap): .toggleAssistiveTechnologyMenu,
        .swipe(.up): .scrollUp,
        .swipe(.down): .scrollDown,
        .tap(.index, .doubleTap): .activate,
        .tap(.middle, .doubleTap): .escape,
        .tap(.middle, .hold): .home,
    ])

    public func action(for gesture: RecognizedGesture) -> BCIAction? { actions[gesture] }
}

/// The gesture → intent → report stage: turns a normalized gesture into button press/release
/// reports and keeps the 32-button state consistent (no stuck buttons).
public struct IntentEncoder: Sendable {
    public private(set) var state = BCIButtonState()
    public init() {}

    /// A discrete band gesture becomes a click: press, then release, preserving other buttons.
    public mutating func reports(for gesture: RecognizedGesture, mapping: IntentMapping) -> (action: BCIAction, reports: [BCIReport])? {
        guard let action = mapping.action(for: gesture), let reports = try? state.click(action.buttonIndex) else { return nil }
        return (action, reports)
    }

    /// For a held input (e.g. a raw press/release pair): press now, release later.
    public mutating func pressReport(_ action: BCIAction) -> BCIReport? { try? state.press(action.buttonIndex) }
    public mutating func releaseReport(_ action: BCIAction) -> BCIReport? { try? state.release(action.buttonIndex) }

    /// Emergency stop: release everything.
    public mutating func releaseAll() -> BCIReport { state.releaseAll() }
}
