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
