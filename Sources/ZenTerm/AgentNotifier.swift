import AppKit
import TabKit
import UserNotifications

/// Delivers native macOS banners when an agent needs attention while ZenTerm is unfocused — the
/// "I walked away" case the in-app sticky toast can't cover (the toast is invisible when the app
/// isn't frontmost). Driven by the same OSC 777/9 desktop-notification signal that drives the toast;
/// this is a second delivery channel, not a second detection path. A `shared` singleton, mirroring
/// `NavRegistry.shared`.
///
/// Banner identity is `(windowID, tabID)`, never the bare tab id: `TabID`s are only unique within a
/// window (each `WindowController` mints from `1`), so two windows' first tabs are both `TabID(1)` —
/// keying on the raw id would let one window's banner replace, clear, or misroute another's.
final class AgentNotifier: NSObject {
    static let shared = AgentNotifier()

    /// Invoked (on the main queue) when the user clicks a delivered banner, carrying the originating
    /// window + tab so the app can jump to it. Set by `AppDelegate`.
    var onActivate: ((Int, TabID) -> Void)?

    /// Notifications need a real app bundle: `UNUserNotificationCenter.current()` throws when
    /// `Bundle.main.bundleIdentifier` is nil. `bin/run` (`swift run ZenTerm`, the mid-flight dev
    /// build) is a bare executable with no bundle id, so every entry point no-ops there — keeping that
    /// workflow crash-free. Packaged builds (`bin/package-app`, the daily driver) carry the id and
    /// deliver for real.
    private let isBundled = Bundle.main.bundleIdentifier != nil

    /// Cached once a grant is observed, so steady-state deliveries skip the `getNotificationSettings`
    /// round-trip to the notification daemon. Main-thread only. A grant never silently downgrades; if
    /// the user later revokes in System Settings, `add` becomes a harmless no-op (the system is the
    /// real gate).
    private var isAuthorized = false

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

    /// Post (or replace) the banner for `(windowID, tabID)`. Authorization is requested lazily on the
    /// first delivery (Apple's HIG contextual pattern — avoids a cold-launch prompt) and never
    /// re-prompts. The request identifier is the window+tab pair, so a fresh event on the same tab
    /// replaces its prior banner instead of stacking (mirrors the toast's `waitingToasts[id]` replace
    /// behavior).
    func notify(windowID: Int, tabID: TabID, title: String, body: String) {
        guard isBundled else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = ["windowID": windowID, "tabID": tabID.raw]
        let request = UNNotificationRequest(
            identifier: identifier(windowID: windowID, tabID: tabID), content: content, trigger: nil)
        withAuthorization { granted in  // delivered on main
            // Re-check focus at add-time: authorization can resolve asynchronously, and if the app
            // regained focus in the meantime the banner would be stale (the user is now looking at the
            // app, and `didBecomeActive` already ran its clear). Dropping it keeps the "unfocused only"
            // contract.
            guard granted, !NSApp.isActive else { return }
            UNUserNotificationCenter.current().add(request)
        }
    }

    /// Drop any delivered or pending banner for `(windowID, tabID)` — the tab was seen, closed, or
    /// dismissed.
    func clear(windowID: Int, tabID: TabID) {
        guard isBundled else { return }
        let id = [identifier(windowID: windowID, tabID: tabID)]
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: id)
        center.removePendingNotificationRequests(withIdentifiers: id)
    }

    private func identifier(windowID: Int, tabID: TabID) -> String { "\(windowID).\(tabID.raw)" }

    /// Resolve authorization, then invoke `completion(granted)` on the main queue. Prompts only while
    /// undetermined (the first delivery); once a grant is seen it's cached and replayed with no daemon
    /// round-trip; a denial re-queries each time so a later System-Settings enable recovers.
    private func withAuthorization(_ completion: @escaping (Bool) -> Void) {
        if isAuthorized {
            completion(true)
            return
        }
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            // `self` is a permanent singleton, so a strong capture can't leak. Hop to main before
            // touching `isAuthorized` (read on the main-only fast path above) and before `completion`.
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
    /// A banner was acted on. Only the default action (a click on the banner body) routes the tab back
    /// to the app; a swipe-dismiss (`UNNotificationDismissActionIdentifier`) must not activate the app.
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
