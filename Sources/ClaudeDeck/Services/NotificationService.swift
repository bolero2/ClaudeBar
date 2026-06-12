import Foundation
import UserNotifications

/// Posts macOS notifications for session/usage events.
///
/// `UNUserNotificationCenter` requires a real app bundle, so this is a no-op
/// when running the bare SPM executable (it only works from `ClaudeDeck.app`).
enum NotificationService {

    /// Notifications need a bundle identifier (i.e. running as `.app`).
    static var available: Bool { Bundle.main.bundleIdentifier != nil }

    static func requestAuthorization() {
        guard available else { return }
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// `sessionId` is carried in userInfo so a click can jump to that session.
    static func post(title: String, body: String, sessionId: String? = nil) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let sessionId { content.userInfo = ["sessionId": sessionId] }
        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
