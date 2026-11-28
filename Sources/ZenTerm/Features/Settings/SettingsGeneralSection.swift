import AgentSetup
import AppKit

final class SettingsGeneralSection: SettingsFormSection {
    override var navTitle: String { "General" }

    static let claudeSetupKey = "claude-setup"
    static let claudeUpdateKey = "claude-update"
    private weak var claudeSetupControl: ToggleSwitch?
    private weak var claudeUpdateButton: AppButton?
    private weak var focusBeforeClaudeSetup: NSView?
    private var claudeSetupState: ClaudeSetup.State = .notInstalled

    override func populate() {
        addGroup("Agents") {
            self.addToggleRow(
                key: "agent-notifications", caption: "Notify me when an agent needs attention",
                blurb: "System banner when the app is unfocused", read: { $0.agentNotifications })
            self.addTextRow(
                key: "agents", caption: "Agent programs",
                blurb: "claude and codex are built in", placeholder: "pi, gemini",
                read: { $0.agents.joined(separator: ", ") })
            self.addClaudeSetupRow()
        }
        addGroup("Notifications") {
            self.addSegmentedRow(
                key: "attention-toast", caption: "Notice for a tab that needs you",
                blurb: nil,
                options: Self.dismissalTitles,
                read: { Self.dismissalIndex($0.attentionToast) },
                token: { LayoutFormat.toastDismissalToken(Self.dismissals[$0]) })
            self.addSegmentedRow(
                key: "completion-toast", caption: "Notice for something that finished",
                blurb: nil,
                options: Self.dismissalTitles,
                read: { Self.dismissalIndex($0.completionToast) },
                token: { LayoutFormat.toastDismissalToken(Self.dismissals[$0]) })
            self.addNumericRow(
                key: "toast-duration", caption: "How long a notice that clears itself stays up",
                blurb: "Seconds", range: 1...60,
                read: { CGFloat($0.toastDuration) })
        }
        addGroup("Keep Awake") {
            self.addSegmentedRow(
                key: "keep-awake-battery-stop", caption: "Stop below battery level",
                blurb: "Ends the hold on battery only",
                options: Self.batteryStopTitles,
                read: { Self.batteryStopIndex($0.keepAwakeBatteryStop) },
                token: { LayoutFormat.batteryStopToken(GeneralConfig.keepAwakeBatteryStops[$0]) })
            self.addNumericRow(
                key: "keep-awake-grace", caption: "Wait after agents finish",
                blurb: "Seconds", range: 0...600,
                read: { CGFloat($0.keepAwakeGrace) }, integer: true)
        }
        addGroup("Updates") {
            self.addToggleRow(
                key: "automatic-update-checks", caption: "Check for updates in the background",
                blurb: nil, read: { $0.automaticUpdateChecks })
        }
    }

    private func addClaudeSetupRow() {
        let caption = "Teach Claude Code to use zen"
        let control = ToggleSwitch { [weak self] on in self?.applyClaudeSetup(on ? .install : .remove) }
        control.setAccessibilityLabel(caption)
        control.isEnabled = false
        claudeSetupControl = control
        addCustomRow(
            key: Self.claudeSetupKey, caption: caption,
            description: "The zen skill and a session hook, in \(ClaudeCodeSetup.folderName)", control: control,
            focusStop: control,
            width: nil, refresh: {})
        addClaudeUpdateRow()
        ClaudeCodeSetup.refresh { [weak self] in self?.showClaudeSetup($0) }
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
        let window = claudeSetupControl?.window
        let controls: [NSView?] = [claudeSetupControl, claudeUpdateButton]
        focusBeforeClaudeSetup = controls.compactMap { $0 }.first { KeyboardFocus.isFocused($0, in: window) }
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
        claudeSetupControl?.setOn(claudeSetupState != .notInstalled)
        claudeSetupControl?.isEnabled = true
        claudeUpdateButton?.isEnabled = true
        showClaudeUpdate()
        restoreFocusAfterClaudeSetup()
    }

    private func restoreFocusAfterClaudeSetup() {
        guard let focused = focusBeforeClaudeSetup else { return }
        focusBeforeClaudeSetup = nil
        let target = focused.isHidden ? claudeSetupControl : focused
        guard let target, let window = target.window, window.firstResponder === window else { return }
        window.makeFirstResponder(target)
    }

    private static func claudeUpdateDescription(for state: ClaudeSetup.State) -> String? {
        switch state {
        case .outdated: "An older version is installed."
        case .edited: "Your zen setup has changes, and updating replaces them."
        case .notInstalled, .newer, .current: nil
        }
    }

    private static let batteryStopTitles = ["Never", "5%", "10%", "20%"]
    private static func batteryStopIndex(_ stop: Int?) -> Int {
        GeneralConfig.keepAwakeBatteryStops.firstIndex(of: stop) ?? 0
    }

    private static let dismissals: [GeneralConfig.ToastDismissal] = [.off, .sticky, .auto]
    private static let dismissalTitles = ["Off", "Sticky", "Auto"]
    private static func dismissalIndex(_ dismissal: GeneralConfig.ToastDismissal) -> Int {
        dismissals.firstIndex(of: dismissal) ?? 0
    }
}
