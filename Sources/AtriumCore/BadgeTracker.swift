import Foundation

/// Turns raw badge readings into what Atrium shows, and decides when something genuinely new arrived.
///  - Title-based badges (web apps) are held through blinking titles: cleared only after `titleHold` without a count.
///  - "New" means an unread level above the one already announced; it resets once the badge is really gone.
public struct BadgeTracker: Sendable {
    public var titleHold: TimeInterval
    private var missingSince: [String: TimeInterval] = [:]
    private var announced: [String: Int] = [:]
    private var primed = false

    public init(titleHold: TimeInterval = 10) { self.titleHold = titleHold }

    /// - readings: the badge read for each app right now (nil = none).
    /// - titleBased: apps whose reading comes from a page title.
    /// - inView: apps you're looking at (no sound for those).
    /// Returns the badges to show and whether to play the "new" sound.
    public mutating func update(now: TimeInterval, readings: [String: BadgeText?], titleBased: Set<String>,
                                shown: [String: BadgeText], inView: Set<String>) -> (badges: [String: BadgeText], newArrival: Bool) {
        var next: [String: BadgeText] = [:]
        for (id, reading) in readings {
            if let reading {
                next[id] = reading
                missingSince[id] = nil
            } else if titleBased.contains(id), let held = shown[id] {
                let since = missingSince[id] ?? now
                missingSince[id] = since
                if now - since < titleHold { next[id] = held }          // still blinking: hold it
            }
        }
        var arrived = false
        for (id, badge) in next {
            let level = Self.level(badge)
            if level > (announced[id] ?? 0) {
                if primed, !inView.contains(id) { arrived = true }
                announced[id] = level
            }
        }
        for id in announced.keys where next[id] == nil { announced[id] = nil }
        primed = true
        return (next, arrived)
    }

    static func level(_ badge: BadgeText) -> Int {
        if case .count(let n) = badge { return n }
        return 1
    }
}
