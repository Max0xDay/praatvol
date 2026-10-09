import AppKit
import UserNotifications

final class Notifications: NSObject, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()

    func configure() {
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, error in
            if let error { AppLog.shared.event("notification-permission-failed", code: (error as NSError).code) }
        }
    }

    func post(title: String, message: String, file: URL?, failure: Bool = false) {
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized else {
                DispatchQueue.main.async {
                    if let file { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                    if failure { showAlert(message, title: title) }
                }
                return
            }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = message
            content.sound = .default
            if let file { content.userInfo = ["path": file.path] }
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            self.center.add(request) { error in
                if let error {
                    AppLog.shared.event("notification-post-failed", code: (error as NSError).code)
                    DispatchQueue.main.async {
                        if let file { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                        showAlert(message, title: title)
                    }
                }
            }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
        willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        if let path = response.notification.request.content.userInfo["path"] as? String {
            DispatchQueue.main.async {
                let url = URL(fileURLWithPath: path)
                if url.pathExtension == "md" {
                    if !NSWorkspace.shared.open(url) { showAlert("No app can open Markdown. Choose an editor in Finder.") }
                } else { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
        }
        completionHandler()
    }
}
