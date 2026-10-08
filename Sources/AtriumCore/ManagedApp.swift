import Foundation

public struct ManagedApp: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var bundleIdentifier: String   // unique key
    public var displayName: String        // refreshed from the bundle at launch
    public var lastKnownPath: String      // fallback when the bundle id can't be resolved
    public var snapWindow: Bool           // per-app opt-out
    public var openAtLogin: Bool          // launched hidden when Atrium starts

    public init(
        id: UUID = UUID(), bundleIdentifier: String, displayName: String, lastKnownPath: String,
        snapWindow: Bool = true, openAtLogin: Bool = false
    ) {
        self.id = id
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
        self.lastKnownPath = lastKnownPath
        self.snapWindow = snapWindow
        self.openAtLogin = openAtLogin
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
    }
}
