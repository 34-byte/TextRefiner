import UserNotifications

/// Sends system notifications for refinement outcomes.
/// Notifications are lightweight — no action buttons, no interaction required.
/// The user is in another app; a notification that requires interaction is friction.
enum NotificationManager {

    /// Request notification permission. Call once during onboarding or first use.
    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// "Done — text refined" — shown after successful refinement.
    static func postSuccess() {
        let content = UNMutableNotificationContent()
        content.title = "TextRefiner"
        content.body = "Done — text refined"
        content.sound = nil // Silent — the text replacement itself is the feedback

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil // Deliver immediately
        )
        UNUserNotificationCenter.current().add(request)
    }

    /// Shows an error notification. Uses the Ollama-specific message for connection failures.
    static func postFailure(error: Error) {
        let content = UNMutableNotificationContent()
        content.title = "TextRefiner"

        if error is OllamaError || error is URLError {
            content.body = "Could not connect to Ollama. Is it running?"
        } else {
            content.body = error.localizedDescription
        }

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
