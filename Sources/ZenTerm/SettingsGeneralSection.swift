import AppKit

/// The General settings section: app-wide preferences that aren't about the terminal surface or the
/// chrome's look. Today it holds Notifications and Updates, each its own group. A
/// `SettingsFormSection` subclass, so it only declares its groups; the base owns the row builder,
/// live-apply debounce, focus stops, and Reset-all. Both toggles default on.
final class SettingsGeneralSection: SettingsFormSection {
    override var navTitle: String { "General" }

    override func populate() {
        addGroup("Notifications") {
            self.addSegmentedRow(
                key: "agent-notifications", caption: "Notify me when an agent needs attention",
                blurb: "System banner when the app is unfocused", options: ["On", "Off"],
                read: { $0.agentNotifications ? 0 : 1 },
                token: { LayoutFormat.boolToken($0 == 0) }, notifiesOnReselect: false)
        }
        addGroup("Updates") {
            self.addSegmentedRow(
                key: "automatic-update-checks", caption: "Check for updates in the background",
                blurb: "ZenTerm looks for a new release; you choose when to install",
                options: ["On", "Off"],
                read: { $0.automaticUpdateChecks ? 0 : 1 },
                token: { LayoutFormat.boolToken($0 == 0) }, notifiesOnReselect: false)
        }
    }
}
