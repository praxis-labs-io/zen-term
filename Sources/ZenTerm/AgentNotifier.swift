import AppKit
import TabKit
import UserNotifications

/// Keyed by `(windowID, tabID)` because a `TabID` is unique only within its window.
final class AgentNotifier: NSObject {
    static let shared = AgentNotifier()

    var onActivate: ((Int, TabID) -> Void)?

    /// A `.app` check, not a bundle id: `UNUserNotificationCenter.current()` throws in the xctest host.
    private let isBundled = Bundle.main.bundleURL.pathExtension == "app"

    private var isAuthorized = false

    private override init() { super.init() }

    static func shouldPushNotification(appActive: Bool, enabled: Bool) -> Bool {
        !appActive && enabled
    }

    func installDelegate() {
        guard isBundled else { return }
        UNUserNotificationCenter.current().delegate = self
    }

    func notify(windowID: Int, tabID: TabID, title: String, body: String) {
        guard isBundled else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = ["windowID": windowID, "tabID": tabID.raw]
        let request = UNNotificationRequest(
            identifier: identifier(windowID: windowID, tabID: tabID), content: content, trigger: nil)
        withAuthorization { granted in
            guard granted, !NSApp.isActive else { return }
            UNUserNotificationCenter.current().add(request)
        }
    }

    func clear(windowID: Int, tabID: TabID) {
        guard isBundled else { return }
        let id = [identifier(windowID: windowID, tabID: tabID)]
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: id)
        center.removePendingNotificationRequests(withIdentifiers: id)
    }

    private func identifier(windowID: Int, tabID: TabID) -> String { "\(windowID).\(tabID.raw)" }

    private func withAuthorization(_ completion: @escaping (Bool) -> Void) {
        if isAuthorized {
            completion(true)
            return
        }
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            let resolve: (Bool) -> Void = { granted in
                DispatchQueue.main.async {
                    if granted { self.isAuthorized = true }
                    completion(granted)
                }
            }
            switch settings.authorizationStatus {
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in resolve(granted) }
            case .authorized, .provisional, .ephemeral:
                resolve(true)
            case .denied:
                resolve(false)
            @unknown default:
                resolve(false)
            }
        }
    }
}

extension AgentNotifier: UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier,
            let windowID = info["windowID"] as? Int, let raw = info["tabID"] as? Int
        {
            DispatchQueue.main.async { [weak self] in self?.onActivate?(windowID, TabID(raw)) }
        }
        completionHandler()
    }
}
