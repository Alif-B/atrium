import Foundation
import Observation
import AtriumCore

@MainActor @Observable
final class Preferences {
    private let defaults = UserDefaults.standard

    @ObservationIgnored var onLayoutChange: (@MainActor () -> Void)?

    var sidebarEdge: SidebarEdge {
        didSet { defaults.set(sidebarEdge.rawValue, forKey: "sidebarEdge"); onLayoutChange?() }
    }
    var snapOnSwitch: Bool { didSet { defaults.set(snapOnSwitch, forKey: "snapOnSwitch") } }
    var showBadges: Bool { didSet { defaults.set(showBadges, forKey: "showBadges") } }
    var restoreLastApp: Bool { didSet { defaults.set(restoreLastApp, forKey: "restoreLastApp") } }
    var lastActiveBundleID: String? { didSet { defaults.set(lastActiveBundleID, forKey: "lastActiveBundleID") } }
    var hasCompletedOnboarding: Bool { didSet { defaults.set(hasCompletedOnboarding, forKey: "hasCompletedOnboarding") } }

    init() {
        let d = UserDefaults.standard
        sidebarEdge = SidebarEdge(rawValue: d.string(forKey: "sidebarEdge") ?? "") ?? .left
        snapOnSwitch = d.object(forKey: "snapOnSwitch") as? Bool ?? true
        showBadges = d.object(forKey: "showBadges") as? Bool ?? true
        restoreLastApp = d.object(forKey: "restoreLastApp") as? Bool ?? true
        lastActiveBundleID = d.string(forKey: "lastActiveBundleID")
        hasCompletedOnboarding = d.bool(forKey: "hasCompletedOnboarding")
    }
}
