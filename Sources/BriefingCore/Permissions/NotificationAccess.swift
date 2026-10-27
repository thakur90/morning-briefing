import Foundation
import UserNotifications

/// Notification permission and posting. Only works inside an app bundle:
/// UNUserNotificationCenter needs a bundle identity.
public enum NotificationAccess {
    public static var isAvailable: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    /// Prompts if needed and returns the resulting state.
    public static func requestAccess() async -> AccessState {
        let center = UNUserNotificationCenter.current()
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: return .granted
        case .denied: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .denied
        }
    }

    public static func post(title: String, body: String) async throws {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        try await UNUserNotificationCenter.current().add(request)
    }
}
