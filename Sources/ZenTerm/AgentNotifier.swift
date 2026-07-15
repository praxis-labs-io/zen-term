import AppKit
import TabKit
import UserNotifications

/// Delivers native macOS banners when an agent needs attention while ZenTerm is unfocused — the
/// "I walked away" case the in-app sticky toast can't cover (the toast is invisible when the app
/// isn't frontmost). Driven by the same OSC 777/9 desktop-notification signal that drives the toast;
/// this is a second delivery channel, not a second detection path. A `shared` singleton, mirroring
/// `NavRegistry.shared`.
final class AgentNotifier: NSObject {
    static let shared = AgentNotifier()

    /// Invoked (on the main queue) when the user clicks a delivered banner, carrying its originating
    /// tab so the app can jump to it. Set by `AppDelegate`.
    var onActivate: ((TabID) -> Void)?

    /// Notifications need a real app bundle: `UNUserNotificationCenter.current()` throws when
    /// `Bundle.main.bundleIdentifier` is nil. `swift run ZenTerm` (the daily dev build) is a bare
    /// executable with no bundle id, so every entry point no-ops there — keeping that workflow
    /// crash-free. Packaged builds (`bin/package-app`) carry the id and deliver for real.
    private let isBundled = Bundle.main.bundleIdentifier != nil

    private override init() { super.init() }

    /// Pure, unit-testable gate: fire an OS banner only when the app is unfocused and the setting is
    /// on. Extracted so the trigger logic is testable without the system singleton.
    static func shouldPushNotification(appActive: Bool, enabled: Bool) -> Bool {
        !appActive && enabled
    }

    /// Become the notification-center delegate so banner clicks route back through `onActivate`.
    /// Assigning the delegate never prompts — only `requestAuthorization` (kept lazy in `notify`) does.
    func installDelegate() {
        guard isBundled else { return }
        UNUserNotificationCenter.current().delegate = self
    }

    /// Post (or replace) the banner for `tabID`. Authorization is requested lazily on the first
    /// delivery (Apple's HIG contextual pattern — avoids a cold-launch prompt) and never re-prompts.
    /// The request identifier is the tab id, so a fresh event on the same tab replaces its prior
    /// banner instead of stacking (mirrors the toast's `waitingToasts[id]` replace behavior).
    func notify(tabID: TabID, title: String, body: String) {
        guard isBundled else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = ["tabID": tabID.raw]
        let request = UNNotificationRequest(
            identifier: identifier(for: tabID), content: content, trigger: nil)
        withAuthorization { granted in
            guard granted else { return }
            UNUserNotificationCenter.current().add(request)
        }
    }

    /// Drop any delivered or pending banner for `tabID` — the tab was seen, closed, or dismissed.
    func clear(tabID: TabID) {
        guard isBundled else { return }
        let id = [identifier(for: tabID)]
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: id)
        center.removePendingNotificationRequests(withIdentifiers: id)
    }

    private func identifier(for tabID: TabID) -> String { String(tabID.raw) }

    /// Resolve authorization once: prompt only while undetermined (the first delivery), replay the
    /// stored decision afterward, and respect a denial. The callback arrives off-main — callers that
    /// touch UI must hop back to main themselves (this path only enqueues a request, which is
    /// thread-safe).
    private func withAuthorization(_ completion: @escaping (Bool) -> Void) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in completion(granted) }
            case .authorized, .provisional, .ephemeral:
                completion(true)
            case .denied:
                completion(false)
            @unknown default:
                completion(false)
            }
        }
    }
}

extension AgentNotifier: UNUserNotificationCenterDelegate {
    /// A banner was clicked: route its originating tab back to the app on the main queue (`onActivate`
    /// activates the app and jumps to the tab).
    func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if let raw = response.notification.request.content.userInfo["tabID"] as? Int {
            DispatchQueue.main.async { [weak self] in self?.onActivate?(TabID(raw)) }
        }
        completionHandler()
    }
}
