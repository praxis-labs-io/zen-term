import AgentSetup
import AppKit

final class SettingsGeneralSection: SettingsFormSection {
    override var navTitle: String { "General" }

    static let claudeSetupKey = "claude-setup"
    private weak var claudeSetupControl: SegmentedControl?
    private var claudeSetupState: ClaudeSetup.State = .notInstalled

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
            self.addClaudeSetupRow()
        }
        addGroup("Notifications") {
            self.addSegmentedRow(
                key: "attention-toast", caption: "Notice for a tab that needs you",
                blurb: "Off shows none; sticky waits to be answered; auto clears itself",
                options: Self.dismissalTitles,
                read: { Self.dismissalIndex($0.attentionToast) },
                token: { LayoutFormat.toastDismissalToken(Self.dismissals[$0]) },
                notifiesOnReselect: false)
            self.addSegmentedRow(
                key: "completion-toast", caption: "Notice for something that finished",
                blurb: "Off shows none; sticky waits to be answered; auto clears itself",
                options: Self.dismissalTitles,
                read: { Self.dismissalIndex($0.completionToast) },
                token: { LayoutFormat.toastDismissalToken(Self.dismissals[$0]) },
                notifiesOnReselect: false)
            self.addNumericRow(
                key: "toast-duration", caption: "How long a notice that clears itself stays up",
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

    private func addClaudeSetupRow() {
        let control = SegmentedControl(options: ["On", "Off"], selectedIndex: 1, notifiesOnReselect: true) {
            [weak self] index in
            self?.applyClaudeSetup(index == 0 ? .install : .remove)
        }
        control.isEnabled = false
        claudeSetupControl = control
        addCustomRow(
            key: Self.claudeSetupKey, caption: "Teach Claude Code to use zen",
            description: "The zen skill and a session hook, in \(ClaudeCodeSetup.folderName)", control: control,
            focusStop: control,
            controlNote: nil, width: nil, refresh: {})
        ClaudeCodeSetup.refresh { [weak self] in self?.showClaudeSetup($0) }
    }

    private func applyClaudeSetup(_ change: ClaudeCodeSetup.Change) {
        claudeSetupControl?.isEnabled = false
        ClaudeCodeSetup.refresh(applying: change) { [weak self] in self?.showClaudeSetup($0) }
    }

    private func showClaudeSetup(_ result: Result<ClaudeSetup.State, ClaudeSetupError>) {
        let row = rowFor(Self.claudeSetupKey)
        switch result {
        case .success(let state):
            claudeSetupState = state
            row?.showMessage(Self.claudeSetupCaption(for: state), kind: .diagnostic)
        case .failure(let error):
            row?.showMessage(error.message)
        }
        claudeSetupControl?.setSelection(claudeSetupState == .notInstalled ? 1 : 0)
        claudeSetupControl?.isEnabled = true
    }

    private static func claudeSetupCaption(for state: ClaudeSetup.State) -> String? {
        switch state {
        case .outdated: "An older version is installed. Choose On to update it."
        case .edited: "Your copy has edits. Choose On to replace it."
        case .notInstalled, .current: nil
        }
    }

    private static let dismissals: [GeneralConfig.ToastDismissal] = [.off, .sticky, .auto]
    private static let dismissalTitles = ["Off", "Sticky", "Auto"]
    private static func dismissalIndex(_ dismissal: GeneralConfig.ToastDismissal) -> Int {
        dismissals.firstIndex(of: dismissal) ?? 0
    }
}
