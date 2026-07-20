import AppKit

/// The Updates settings section (ZEN-19): a single toggle for background update checks. A
/// `SettingsFormSection` subclass — it only declares its one group; the base owns the row builder,
/// live-apply debounce, focus stops, and Reset-all. Default is on; this is the off switch, driving
/// Sparkle's automatic-check schedule. Inert in an unpackaged dev build (the updater never checks).
final class SettingsUpdatesSection: SettingsFormSection {
    override var navTitle: String { "Updates" }

    override func populate() {
        addGroup("Automatic updates") {
            self.addSegmentedRow(
                key: "automatic-update-checks", caption: "Check for updates in the background",
                blurb: "ZenTerm looks for a new release; you choose when to install",
                options: ["On", "Off"],
                read: { $0.automaticUpdateChecks ? 0 : 1 },
                token: { LayoutFormat.boolToken($0 == 0) }, notifiesOnReselect: false)
        }
    }
}
