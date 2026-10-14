import AppKit
import OSLog
import UserNotifications

private let log = Logger(subsystem: "com.alif.atrium", category: "web")

/// Shows web apps' notifications as Mac notifications (from Atrium), and opens the right app when one is clicked.
/// Silent: Atrium's own badge sound (Settings) already says something arrived.
@MainActor
final class WebNotifier: NSObject {
    /// A notification was clicked: the web app's id and the page's own id for it.
    var onClick: (@MainActor (_ appID: String, _ noteID: String) -> Void)?
    private var allowed: Bool?

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func post(appID: String, appName: String, title: String, body: String, noteID: String) {
        Task {
            let center = UNUserNotificationCenter.current()
            if allowed == nil {
                allowed = (try? await center.requestAuthorization(options: [.alert])) ?? false   // asked once, the first time
                if allowed == false { log.notice("notifications aren't allowed for Atrium") }
            }
            guard allowed == true else { return }
            let content = UNMutableNotificationContent()
            content.title = title.isEmpty ? appName : title
            content.subtitle = title.isEmpty ? "" : appName
            content.body = body
            content.threadIdentifier = appID
            content.userInfo = ["app": appID, "note": noteID]
            try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}

extension WebNotifier: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let app = info["app"] as? String else { return }
        let note = info["note"] as? String ?? ""
        await MainActor.run { self.onClick?(app, note) }
    }
}
