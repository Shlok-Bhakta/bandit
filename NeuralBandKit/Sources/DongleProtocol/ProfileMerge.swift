import Foundation

/// A piece of a profile set that can change on its own: what the app compares, reverts and merges.
public enum ProfileSetPart: Hashable, Sendable {
    case name, menu, start, everywhere, buzzes, feedback
    /// One profile, by id (present on one side only: added or removed).
    case profile(String)
    /// The order of the profiles both sides have.
    case order

    /// The set-wide parts, in the order the app lists them.
    public static let setWide: [Self] = [.name, .menu, .start, .everywhere, .buzzes, .feedback]
}

extension GestureProfileSet {
    /// The parts where `self` and `other` differ: set-wide parts, then profiles in `self`'s order
    /// (then `other`'s), then the order.
    public func differences(from other: GestureProfileSet) -> [ProfileSetPart] {
        let ids = self.ids + other.ids.filter { !self.ids.contains($0) }
        let parts = ProfileSetPart.setWide + ids.map(ProfileSetPart.profile) + [.order]
        return parts.filter { !same($0, as: other) }
    }

    /// Whether `part` is the same here and in `other`.
    public func same(_ part: ProfileSetPart, as other: GestureProfileSet) -> Bool {
        switch part {
        case .name: (name ?? "") == (other.name ?? "")
        case .menu: menu == other.menu
        case .start: start == other.start
        case .everywhere: everywhere == other.everywhere
        case .buzzes: buzzes == other.buzzes
        case .feedback: feedback == other.feedback
        case .profile(let id): profile(id: id) == other.profile(id: id)
        case .order: commonOrder(with: other) == other.commonOrder(with: self)
        }
    }

    /// Profile ids `other` has too, in this set's order.
    func commonOrder(with other: GestureProfileSet) -> [String] {
        let theirs = Set(other.ids)
        return ids.filter(theirs.contains)
    }

    /// This set with `part` as `other` has it. A profile keeps its identity in the app when it's
    /// on both sides (an open editor stays on it); one only `other` has goes after the profile it
    /// follows there.
    public func replacing(_ part: ProfileSetPart, from other: GestureProfileSet) -> GestureProfileSet {
        var next = self
        switch part {
        case .name: next.name = other.name
        case .menu: next.menu = other.menu
        case .start: next.start = other.start
        case .everywhere: next.everywhere = other.everywhere
        case .buzzes: next.buzzes = other.buzzes
        case .feedback: next.feedback = other.feedback
        case .profile(let id):
            let mine = next.profiles.firstIndex { $0.id == id }
            switch (mine, other.profile(id: id)) {
            case (let index?, var theirs?):
                theirs.uid = next.profiles[index].uid
                next.profiles[index] = theirs
            case (let index?, nil):
                next.profiles.remove(at: index)
            case (nil, let theirs?):
                next.profiles.insert(theirs, at: next.insertionIndex(for: id, following: other))
            case (nil, nil):
                break
            }
        case .order:
            let order = other.commonOrder(with: next)
            var slots = next.profiles.indices.filter { order.contains(next.profiles[$0].id) }.makeIterator()
            let reordered = next.profiles
            for id in order {
                guard let slot = slots.next(), let profile = reordered.first(where: { $0.id == id }) else { break }
                next.profiles[slot] = profile
            }
        }
        return next
    }

    /// Where a profile `other` has goes here: after the nearest profile before it there that this
    /// set has, else first.
    private func insertionIndex(for id: String, following other: GestureProfileSet) -> Int {
        guard let position = other.ids.firstIndex(of: id) else { return profiles.count }
        for before in other.ids[..<position].reversed() {
            if let index = profiles.firstIndex(where: { $0.id == before }) { return index + 1 }
        }
        return 0
    }
}

/// Two versions of a set (this phone's and another: the dongle's, or a file), with the version
/// they both came from when it's known. Parts only one side changed since then take that side;
/// parts both changed (or every difference, with no common version) are conflicts to pick.
public struct ProfileMerge: Sendable {
    public enum Side: Sendable { case phone, other }

    public enum Change: Sendable {
        /// Changed on this phone only.
        case phone
        /// Changed on the other side only.
        case other
        /// Changed on both, or no common version to tell: the user picks.
        case both
    }

    public struct Item: Identifiable, Sendable {
        public let part: ProfileSetPart
        public let change: Change
        public var pick: Side
        public var id: ProfileSetPart { part }
    }

    public let base: GestureProfileSet?
    public let phone: GestureProfileSet
    public let other: GestureProfileSet
    public var items: [Item]

    /// `prefer` is the side a conflict starts on.
    public init(base: GestureProfileSet?, phone: GestureProfileSet, other: GestureProfileSet, prefer: Side = .phone) {
        self.base = base
        self.phone = phone
        self.other = other
        items = phone.differences(from: other).map { part in
            guard let base else { return Item(part: part, change: .both, pick: prefer) }
            if base.same(part, as: phone) { return Item(part: part, change: .other, pick: .other) }
            if base.same(part, as: other) { return Item(part: part, change: .phone, pick: .phone) }
            return Item(part: part, change: .both, pick: prefer)
        }
    }

    public var conflicts: [Item] { items.filter { $0.change == .both } }

    public mutating func pickAll(_ side: Side) {
        for index in items.indices { items[index].pick = side }
    }

    /// The phone's set with every part picked from the other side taken from it (the order last,
    /// so it sees the profiles the merge keeps).
    public var result: GestureProfileSet {
        let taken = items.filter { $0.pick == .other }.map(\.part)
        var merged = taken.filter { $0 != .order }.reduce(phone) { $0.replacing($1, from: other) }
        if taken.contains(.order) { merged = merged.replacing(.order, from: other) }
        return merged
    }
}
