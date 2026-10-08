import Foundation

/// When an idle app should be put to sleep. Times are seconds on a clock that doesn't run while the Mac sleeps
/// (`ProcessInfo.systemUptime`), so a night's sleep is not "15 minutes of no use".
public enum Hibernation {
    public static let idleLimit: TimeInterval = 15 * 60

    public static func shouldHibernate(now: TimeInterval, lastUsed: TimeInterval, limit: TimeInterval = idleLimit) -> Bool {
        now - lastUsed >= limit
    }
}
