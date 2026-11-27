import AgentSetup
import AppKit

final class SettingsGeneralSection: SettingsFormSection {
    override var navTitle: String { "General" }

    static let claudeSetupKey = "claude-setup"
    static let claudeUpdateKey = "claude-update"
    static let piSetupKey = "pi-setup"
    static let piUpdateKey = "pi-update"
    private weak var claudeSetupControl: SegmentedControl?
    private weak var claudeUpdateButton: AppButton?
    private weak var piSetupControl: SegmentedControl?
    private weak var piUpdateButton: AppButton?
    private var claudeSetupState: ClaudeSetup.State = .notInstalled
    private var piSetupState: PiSetup.State = .notInstalled

    override func populate() {
        addGroup("Agents") {
            self.addSegmentedRow(
                key: "agent-notifications", caption: "Notify me when an agent needs attention",
                blurb: "System banner when the app is unfocused", options: ["On", "Off"],
                read: { $0.agentNotifications ? 0 : 1 },
                token: { LayoutFormat.boolToken($0 == 0) }, notifiesOnReselect: false)
            self.addTextRow(
                key: "agents", caption: "Agent programs",
                blurb: "claude, codex and pi are built in", placeholder: "gemini",
                read: { $0.agents.joined(separator: ", ") })
            self.addClaudeSetupRow()
            self.addPiSetupRow()
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
            width: nil, refresh: {})
        addClaudeUpdateRow()
        ClaudeCodeSetup.refresh { [weak self] in self?.showClaudeSetup($0) }
    }

    private func addPiSetupRow() {
        let control = SegmentedControl(options: ["On", "Off"], selectedIndex: 1, notifiesOnReselect: true) {
            [weak self] index in
            self?.applyPiSetup(index == 0 ? .install : .remove)
        }
        control.isEnabled = false
        piSetupControl = control
        addCustomRow(
            key: Self.piSetupKey, caption: "Teach Pi to use zen",
            description: "The zen skill and extension, in \(PiCodeSetup.folderName)", control: control,
            focusStop: control, width: nil, refresh: {})
        addPiUpdateRow()
        PiCodeSetup.refresh { [weak self] in self?.showPiSetup($0) }
    }

    private func addPiUpdateRow() {
        let update = AppButton(title: "Update", variant: .muted)
        update.isKeyboardFocusable = true
        update.onTap = { [weak self] in self?.applyPiSetup(.install) }
        piUpdateButton = update
        addCustomRow(
            key: Self.piUpdateKey, caption: "Update zen for Pi", description: "", control: update,
            focusStop: update, width: nil,
            refresh: { [weak self] in self?.showPiUpdate() })
        showPiUpdate()
    }

    private func showPiUpdate() {
        let description = Self.piUpdateDescription(for: piSetupState)
        let row = rowFor(Self.piUpdateKey)
        row?.setDescription(description ?? "")
        row?.isHidden = description == nil
        piUpdateButton?.isHidden = description == nil
    }

    private func applyPiSetup(_ change: PiCodeSetup.Change) {
        piSetupControl?.isEnabled = false
        piUpdateButton?.isEnabled = false
        PiCodeSetup.refresh(applying: change) { [weak self] in self?.showPiSetup($0) }
    }

    private func showPiSetup(_ result: Result<PiSetup.State, PiSetupError>) {
        let row = rowFor(Self.piSetupKey)
        switch result {
        case .success(let state):
            piSetupState = state
            row?.showMessage(nil)
        case .failure(let error): row?.showMessage(error.message)
        }
        piSetupControl?.setSelection(piSetupState == .notInstalled ? 1 : 0)
        piSetupControl?.isEnabled = true
        piUpdateButton?.isEnabled = true
        showPiUpdate()
    }

    private static func piUpdateDescription(for state: PiSetup.State) -> String? {
        switch state {
        case .outdated: "An older version is installed."
        case .edited: "Your zen setup has changes, and updating replaces them."
        case .notInstalled, .newer, .current: nil
        }
    }

    private func addClaudeUpdateRow() {
        let update = AppButton(title: "Update", variant: .muted)
        update.isKeyboardFocusable = true
        update.onTap = { [weak self] in self?.applyClaudeSetup(.install) }
        claudeUpdateButton = update
        addCustomRow(
            key: Self.claudeUpdateKey, caption: "Update zen for Claude Code", description: "", control: update,
            focusStop: update, width: nil,
            refresh: { [weak self] in self?.showClaudeUpdate() })
        showClaudeUpdate()
    }

    private func showClaudeUpdate() {
        let description = Self.claudeUpdateDescription(for: claudeSetupState)
        let row = rowFor(Self.claudeUpdateKey)
        row?.setDescription(description ?? "")
        row?.isHidden = description == nil
        claudeUpdateButton?.isHidden = description == nil
    }

    private func applyClaudeSetup(_ change: ClaudeCodeSetup.Change) {
        claudeSetupControl?.isEnabled = false
        claudeUpdateButton?.isEnabled = false
        ClaudeCodeSetup.refresh(applying: change) { [weak self] in self?.showClaudeSetup($0) }
    }

    private func showClaudeSetup(_ result: Result<ClaudeSetup.State, ClaudeSetupError>) {
        let row = rowFor(Self.claudeSetupKey)
        switch result {
        case .success(let state):
            claudeSetupState = state
            row?.showMessage(nil)
        case .failure(let error):
            row?.showMessage(error.message)
        }
        claudeSetupControl?.setSelection(claudeSetupState == .notInstalled ? 1 : 0)
        claudeSetupControl?.isEnabled = true
        claudeUpdateButton?.isEnabled = true
        showClaudeUpdate()
    }

    private static func claudeUpdateDescription(for state: ClaudeSetup.State) -> String? {
        switch state {
        case .outdated: "An older version is installed."
        case .edited: "Your zen setup has changes, and updating replaces them."
        case .notInstalled, .newer, .current: nil
        }
    }

    private static let dismissals: [GeneralConfig.ToastDismissal] = [.off, .sticky, .auto]
    private static let dismissalTitles = ["Off", "Sticky", "Auto"]
    private static func dismissalIndex(_ dismissal: GeneralConfig.ToastDismissal) -> Int {
        dismissals.firstIndex(of: dismissal) ?? 0
    }
}
