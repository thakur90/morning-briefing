import AppKit
import UserNotifications

/// Posts briefing notifications; clicking one opens the briefing page (design doc §7).
/// Needs the app bundle (UNUserNotificationCenter requires a bundle identity).
@MainActor
public final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    public static let shared = Notifier()
    nonisolated static let urlKey = "url"

    /// Call once at agent start so clicks are routed here.
    public func activate() {
        UNUserNotificationCenter.current().delegate = self
    }

    public func post(title: String, body: String, opening url: URL, thread: String) async throws {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.threadIdentifier = thread
        content.userInfo = [Self.urlKey: url.absoluteString]
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        try await UNUserNotificationCenter.current().add(request)
    }

    public nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        guard let string = response.notification.request.content.userInfo[Self.urlKey] as? String,
              let url = URL(string: string), url.isFileURL else { return }
        _ = await MainActor.run { NSWorkspace.shared.open(url) }
    }

    /// Show banners even though the agent counts as the "current app" for its own notifications.
    public nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
