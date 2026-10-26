import AppKit
import UserNotifications

struct AlertEvent: Identifiable {
    let id = UUID()
    let date: Date
    let title: String
    let body: String
    let severity: Severity
}

/// One thing worth a notification: an unhealthy server or a firing SigNoz rule.
struct Item {
    let key: String, title: String, body: String, severity: Severity, path: String
}

final class Alerter: NSObject, UNUserNotificationCenterDelegate {
    private var lastFired: [String: Date] = [:]
    var onAlert: ((AlertEvent) -> Void)?
    var onOpen: ((String) -> Void)?

    func setup() {
        let c = UNUserNotificationCenter.current()
        c.delegate = self
        c.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Which items get a notification now: each key at most once per cooldown.
    func evaluate(_ items: [Item], cooldownMin: Double, now: Date = Date()) -> [Item] {
        items.filter { item in
            if let last = lastFired[item.key], now.timeIntervalSince(last) < cooldownMin * 60 { return false }
            lastFired[item.key] = now
            return true
        }
    }

    func check(_ rows: [Row], firing: [Alert], _ t: Thresholds) {
        var items = rows.filter { $0.health.sev == .bad }.map {
            Item(key: $0.id, title: "\($0.server.name) is unhealthy", body: $0.health.why, severity: .bad, path: $0.server.path)
        }
        items += firing.map { Item(key: "alert:" + $0.id, title: $0.name, body: $0.detail.isEmpty ? "\($0.severity) alert firing" : $0.detail, severity: $0.sev, path: $0.path) }
        for i in evaluate(items, cooldownMin: t.cooldownMin) {
            let content = UNMutableNotificationContent()
            content.title = i.title
            content.body = i.body
            content.sound = .default
            content.userInfo = ["path": i.path]
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: i.key, content: content, trigger: nil))
            onAlert?(AlertEvent(date: Date(), title: i.title, body: i.body, severity: i.severity))
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    /// Clicking a notification opens that server or rule in SigNoz.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let path = response.notification.request.content.userInfo["path"] as? String { onOpen?(path) }
        completionHandler()
    }
}
