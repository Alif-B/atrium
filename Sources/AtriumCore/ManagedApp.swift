import Foundation

public struct ManagedApp: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var bundleIdentifier: String   // unique key
    public var displayName: String        // refreshed from the bundle at launch
    public var lastKnownPath: String      // fallback when the bundle id can't be resolved
    public var snapWindow: Bool           // per-app opt-out
    public var openAtLogin: Bool          // launched hidden when Atrium starts
    /// Web apps only: the site and a cached icon PNG. (`browserBundleID` is from when web apps ran in Edge: unused.)
    public var webURL: String?
    public var browserBundleID: String?
    public var iconFile: String?
    /// True when the user chose the icon themselves; it is never replaced by the site's.
    public var customIcon: Bool
    /// The picture the user chose (kept so its size can be changed later) and how large it sits in its space (0.4–1.0).
    public var iconSource: String?
    public var iconScale: Double?
    /// Quit this app (or close its window, for a web app) after 15 minutes without use. Off unless the user turns it on.
    public var hibernates: Bool

    public var isWebApp: Bool { webURL != nil }
    public static let webAppIDPrefix = "atrium.web."

    public init(
        id: UUID = UUID(), bundleIdentifier: String, displayName: String, lastKnownPath: String,
        snapWindow: Bool = true, openAtLogin: Bool = false,
        webURL: String? = nil, browserBundleID: String? = nil, iconFile: String? = nil, customIcon: Bool = false,
        iconSource: String? = nil, iconScale: Double? = nil, hibernates: Bool = false
    ) {
        self.id = id
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
        self.lastKnownPath = lastKnownPath
        self.snapWindow = snapWindow
        self.openAtLogin = openAtLogin
        self.webURL = webURL
        self.browserBundleID = browserBundleID
        self.iconFile = iconFile
        self.customIcon = customIcon
        self.iconSource = iconSource
        self.iconScale = iconScale
        self.hibernates = hibernates
    }

    // Synthesized Codable ignores property defaults, so older JSON files need decodeIfPresent.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        bundleIdentifier = try c.decode(String.self, forKey: .bundleIdentifier)
        displayName = try c.decode(String.self, forKey: .displayName)
        lastKnownPath = try c.decodeIfPresent(String.self, forKey: .lastKnownPath) ?? ""
        snapWindow = try c.decodeIfPresent(Bool.self, forKey: .snapWindow) ?? true
        openAtLogin = try c.decodeIfPresent(Bool.self, forKey: .openAtLogin) ?? false
        webURL = try c.decodeIfPresent(String.self, forKey: .webURL)
        browserBundleID = try c.decodeIfPresent(String.self, forKey: .browserBundleID)
        iconFile = try c.decodeIfPresent(String.self, forKey: .iconFile)
        customIcon = try c.decodeIfPresent(Bool.self, forKey: .customIcon) ?? false
        iconSource = try c.decodeIfPresent(String.self, forKey: .iconSource)
        iconScale = try c.decodeIfPresent(Double.self, forKey: .iconScale)
        hibernates = try c.decodeIfPresent(Bool.self, forKey: .hibernates) ?? false
    }
}

public enum WebAddress {
    /// "jira.acme.com/board" → "https://jira.acme.com/board". Nil if it doesn't look like a web address.
    public static func normalize(_ input: String) -> URL? {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, !s.contains(" ") else { return nil }
        if !s.lowercased().hasPrefix("http://") && !s.lowercased().hasPrefix("https://") { s = "https://" + s }
        guard let url = URL(string: s), let host = url.host(), host.contains(".") || host == "localhost" else { return nil }
        return url
    }

    /// A friendly default name from the host: "mail.google.com" → "Mail", "acme.atlassian.net" → "Acme".
    public static func suggestedName(for url: URL) -> String {
        let host = (url.host() ?? "").replacingOccurrences(of: "www.", with: "")
        let first = host.split(separator: ".").first.map(String.init) ?? host
        return first.prefix(1).uppercased() + first.dropFirst()
    }
}
