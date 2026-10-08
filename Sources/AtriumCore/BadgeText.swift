import Foundation

/// A normalized Dock badge.
public enum BadgeText: Equatable, Sendable {
    case count(Int)
    case text(String)
    case dot

    private static let dotMarkers: Set<String> = [".", "•", "●", "·", "∙"]

    public static func parse(_ raw: String) -> BadgeText? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return nil }
        if let n = Int(s) { return n > 0 ? .count(n) : nil }
        if dotMarkers.contains(s) { return .dot }
        return s.count <= 3 ? .text(s) : .dot
    }

    /// What to draw. `.dot` has no text.
    public var display: String {
        switch self {
        case .count(let n): n > 99 ? "99+" : String(n)
        case .text(let s): s
        case .dot: ""
        }
    }
}

/// Web pages announce unread items in their title: "Inbox (12) - me@gmail.com", "(3) Messenger", "[2] Chat".
/// (Edge shows no Dock badge for these windows, so the title is the only signal.)
public enum TitleBadge {
    public static func parse(_ title: String) -> BadgeText? {
        guard let regex = try? NSRegularExpression(pattern: "[\\(\\[](\\d{1,4})[\\)\\]]") else { return nil }
        let range = NSRange(title.startIndex..., in: title)
        for match in regex.matches(in: title, range: range) {
            guard let r = Range(match.range(at: 1), in: title), let n = Int(title[r]) else { continue }
            if (1900...2100).contains(n) { continue }          // a year, not a count
            if n > 0 { return .count(n) }
        }
        return nil
    }
}
