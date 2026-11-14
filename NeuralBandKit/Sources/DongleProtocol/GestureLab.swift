import Foundation

/// Log records tolerate unknown band values, which are useful evidence in the lab.
public enum GestureLabRecord: Equatable, Sendable {
    case message(sequence: Int, finger: String, action: String, derived: String)
    case fired(gesture: String, profile: String, action: String)
    case fields(String)
    case motion(flick: Bool, direction: String, peak: String)

    public static func parse(_ line: String) -> Self? {
        if let range = line.range(of: "gesture #") {
            let body = line[range.upperBound...]
            guard let colon = body.firstIndex(of: ":"), let sequence = Int(body[..<colon]) else { return nil }
            let parts = body[body.index(after: colon)...].split(separator: " ").map(String.init)
            guard parts.count >= 3 else { return nil }
            return .message(sequence: sequence, finger: parts[0], action: parts[1], derived: parts[2])
        }
        if let range = line.range(of: "GESTURE: ") {
            let body = String(line[range.upperBound...])
            guard let split = body.range(of: " in "), let colon = body[split.upperBound...].range(of: ": ") else { return nil }
            return .fired(gesture: String(body[..<split.lowerBound]), profile: String(body[split.upperBound..<colon.lowerBound]), action: String(body[colon.upperBound...]))
        }
        if let range = line.range(of: "LAB fields ") { return .fields(String(line[range.upperBound...])) }
        for (prefix, flick) in [("LAB flick ", true), ("LAB swing ", false)] {
            if let range = line.range(of: prefix) {
                let parts = line[range.upperBound...].split(separator: " ", maxSplits: 1)
                guard parts.count == 2 else { return nil }
                return .motion(flick: flick, direction: String(parts[0]), peak: String(parts[1]))
            }
        }
        return nil
    }

    public static func bandNames(finger: String, action: String, derived: String) -> [String] {
        var events: [String] = []
        for name in [action, derived] where ProfileGesture.bandEvents.contains(name) && !events.contains(name) { events.append(name) }
        let specific = ProfileGesture.bandFingers.contains(finger) ? events.map { "band.\(finger).\($0)" } : []
        return specific + events.map { "band.\($0)" }
    }
    public static func namedGestures(finger: String, action: String, derived: String) -> [String] {
        let events = [action, derived]
        if ["index", "middle"].contains(finger), events.contains("singleTap") { return ["\(finger).tap"] }
        if ["index", "middle"].contains(finger), events.contains("doubleTap") { return ["\(finger).doubleTap"] }
        if finger == "middle", events.contains("buttonHold") { return ["middle.hold"] }
        if finger == "thumb" {
            return ["up", "down", "left", "right"].filter { events.contains($0) || events.contains("button" + $0.capitalized) }.map { "swipe.\($0)" }
        }
        return []
    }
}
