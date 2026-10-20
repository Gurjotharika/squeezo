import Foundation
import UserNotifications

/// Local notifications for finished batches.
enum Notifier {
    static func post(compressed: Int, failed: Int, savedBytes: Int64) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = failed == 0 ? "Finished" : "Finished with problems"
            var body = "\(compressed) \(compressed == 1 ? "file" : "files") compressed"
            if savedBytes > 0 { body += ", saved \(savedBytes.formatted(.byteCount(style: .file)))" }
            if failed > 0 { body += ". \(failed) failed." }
            content.body = body
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}
