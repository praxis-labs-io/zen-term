import AppKit

final class SettingsGeneralSection: SettingsFormSection {
    override var navTitle: String { "General" }

    static let claudeSetupKey = "claude-setup"
    static let claudeUpdateKey = "claude-update"
    private let claudeRows = SetupRows<ClaudeCodeSetup>(setupKey: claudeSetupKey, updateKey: claudeUpdateKey)

    override func populate() {
        addGroup("Agents") {
            self.addSegmentedRow(
                key: "agent-notifications", caption: "Notify me when an agent needs attention",
                blurb: "System banner when the app is unfocused", options: ["On", "Off"],
                read: { $0.agentNotifications ? 0 : 1 },
                token: { LayoutFormat.boolToken($0 == 0) }, notifiesOnReselect: false)
            self.addTextRow(
                key: "agents", caption: "Agent programs",
                blurb: "claude and codex are built in", placeholder: "pi, gemini",
                read: { $0.agents.joined(separator: ", ") })
            self.claudeRows.add(
                to: self, caption: "Teach Claude Code to use zen",
                description: "The zen skill and a session hook, in \(ClaudeCodeSetup.folderName)",
                updateCaption: "Update zen for Claude Code")
        }
        addGroup("Notifications") {
            self.addSegmentedRow(
                key: "attention-toast", caption: "Notice for a tab that needs you",
                blurb: nil,
                options: Self.dismissalTitles,
                read: { Self.dismissalIndex($0.attentionToast) },
                token: { LayoutFormat.toastDismissalToken(Self.dismissals[$0]) },
                notifiesOnReselect: false)
            self.addSegmentedRow(
                key: "completion-toast", caption: "Notice for something that finished",
                blurb: nil,
                options: Self.dismissalTitles,
                read: { Self.dismissalIndex($0.completionToast) },
                token: { LayoutFormat.toastDismissalToken(Self.dismissals[$0]) },
                notifiesOnReselect: false)
            self.addNumericRow(
                key: "toast-duration", caption: "How long a notice that clears itself stays up",
                blurb: "Seconds", range: 1...60,
                read: { CGFloat($0.toastDuration) })
        }
        addGroup("Updates") {
            self.addSegmentedRow(
                key: "automatic-update-checks", caption: "Check for updates in the background",
                blurb: nil,
                options: ["On", "Off"],
                read: { $0.automaticUpdateChecks ? 0 : 1 },
                token: { LayoutFormat.boolToken($0 == 0) }, notifiesOnReselect: false)
        }
    }

    private static let dismissals: [GeneralConfig.ToastDismissal] = [.off, .sticky, .auto]
    private static let dismissalTitles = ["Off", "Sticky", "Auto"]
    private static func dismissalIndex(_ dismissal: GeneralConfig.ToastDismissal) -> Int {
        dismissals.firstIndex(of: dismissal) ?? 0
    }
}
