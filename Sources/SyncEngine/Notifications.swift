/// macOS notifications via UserNotifications framework.
///
/// Ported from Python CLI `src/plaude/notify.py`.

import Foundation
import UserNotifications

/// Send a macOS notification.
public func sendNotification(title: String, body: String, subtitle: String = "") {
    let center = UNUserNotificationCenter.current()

    center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
        guard granted else { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if !subtitle.isEmpty { content.subtitle = subtitle }
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        center.add(request)
    }
}
