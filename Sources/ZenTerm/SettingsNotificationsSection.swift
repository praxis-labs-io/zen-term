import AppKit

/// The Notifications settings section (ZEN-139): a single toggle for OS banners when an agent needs
/// attention while ZenTerm is unfocused. A `SettingsFormSection` subclass — it only declares its one
/// group; the base owns the row builder, live-apply debounce, focus stops, and Reset-all. Default is
/// on; the macOS notification permission is the real gate.
final class SettingsNotificationsSection: SettingsFormSection {
    override var navTitle: String { "Notifications" }

    override func populate() {
        addGroup("Alerts") {
            self.addSegmentedRow(
                key: "agent-notifications", caption: "Notify me when an agent needs attention",
                blurb: "System banner when the app is unfocused", options: ["On", "Off"],
                read: { $0.agentNotifications ? 0 : 1 },
                token: { LayoutFormat.boolToken($0 == 0) }, notifiesOnReselect: false)
        }
    }
}
