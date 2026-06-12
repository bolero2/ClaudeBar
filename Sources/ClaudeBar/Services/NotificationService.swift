import Foundation
import UserNotifications

/// Posts macOS notifications for session/usage events.
///
/// `UNUserNotificationCenter` requires a real app bundle, so this is a no-op
/// when running the bare SPM executable (it only works from `ClaudeBar.app`).
enum NotificationService {

    /// Notifications need a bundle identifier (i.e. running as `.app`).
    static var available: Bool { Bundle.main.bundleIdentifier != nil }

    static func requestAuthorization() {
        guard available else { return }
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(title: String, body: String) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
