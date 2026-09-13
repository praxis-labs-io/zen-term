import AppKit

final class SettingsGeneralSection: SettingsFormSection {
    override var navTitle: String { "General" }

    override func populate() {
        addGroup("Notifications") {
            self.addSegmentedRow(
                key: "agent-notifications", caption: "Notify me when an agent needs attention",
                blurb: "System banner when the app is unfocused", options: ["On", "Off"],
                read: { $0.agentNotifications ? 0 : 1 },
                token: { LayoutFormat.boolToken($0 == 0) }, notifiesOnReselect: false)
            self.addSegmentedRow(
                key: "attention-toast", caption: "Card for a tab that needs you",
                blurb: "Sticky waits to be answered; auto clears itself",
                options: Self.dismissalTitles,
                read: { Self.dismissalIndex($0.attentionToast) },
                token: { LayoutFormat.toastDismissalToken(Self.dismissals[$0]) },
                notifiesOnReselect: false)
            self.addSegmentedRow(
                key: "completion-toast", caption: "Card for a command that finished",
                blurb: "Sticky waits to be answered; auto clears itself",
                options: Self.dismissalTitles,
                read: { Self.dismissalIndex($0.completionToast) },
                token: { LayoutFormat.toastDismissalToken(Self.dismissals[$0]) },
                notifiesOnReselect: false)
            self.addNumericRow(
                key: "toast-duration", caption: "How long a card that clears itself stays up",
                blurb: "Seconds, for every notice that clears itself", range: 1...60,
                read: { CGFloat($0.toastDuration) })
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

    /// Static so the row closures do not capture and retain the section.
    private static let dismissals: [GeneralConfig.ToastDismissal] = [.sticky, .auto]
    private static let dismissalTitles = ["Sticky", "Auto"]
    private static func dismissalIndex(_ dismissal: GeneralConfig.ToastDismissal) -> Int {
        dismissals.firstIndex(of: dismissal) ?? 0
    }
}
