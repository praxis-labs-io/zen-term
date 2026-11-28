import Foundation

// The window's toast copy, built here so the Component Gallery shows what the app shows.
extension WindowController {
    static func diagnosticsExportedToast(file: String) -> ToastContent {
        ToastContent(
            variant: .positive, title: "Diagnostics exported",
            message: "Saved \(file). It holds your logs and system info.")
    }

    static func diagnosticsExportFailedToast(reason: String) -> ToastContent {
        ToastContent(
            variant: .warning, title: "Export failed", message: "Couldn't write the diagnostics file: \(reason)")
    }

    static func floatBlockedToast(isPane: Bool, name: String?) -> ToastContent {
        isPane
            ? ToastContent(
                variant: .info, title: "Float pane",
                message: "\(name ?? "This float pane") is open. Close it to get back to your panes.")
            : ToastContent(
                variant: .info, title: "Tool float",
                message: "\(name ?? "This tool") is open. Close it to get back to your panes.")
    }

    static func newWorktreeRefusedToast(_ refusal: SidebarController.NewWorktreeRefusal) -> ToastContent {
        ToastContent(variant: .info, title: "New worktree", message: refusal.message)
    }

    static func loginFailedToast(host: String) -> ToastContent {
        ToastContent(variant: .warning, title: "Couldn't connect to", titleTail: " \(host)", message: nil)
    }

    static func floatsStayLocalToast(host: String) -> ToastContent {
        ToastContent(
            variant: .info, title: "Tool floats", message: "Tool floats run on this Mac, not on \(host).")
    }

    static func newWorktreeMissingToast(name: String) -> ToastContent {
        ToastContent(
            variant: .warning, title: "Couldn't open new worktree",
            message: "\(name) is no longer in the workspaces file.")
    }

    static func worktreeCreateFailedToast(reason: String) -> ToastContent {
        ToastContent(variant: .warning, title: "Couldn't create the worktree", message: reason)
    }

    static func carryLostToast(_ lost: String) -> ToastContent {
        ToastContent(variant: .warning, title: "Couldn't copy everything", message: "\(lost).")
    }

    static func openInAnotherWindowToast(name: String) -> ToastContent {
        ToastContent(
            variant: .info, title: "Open in another window",
            message: "Close \(name) from the window it is open in.")
    }

    static func worktreeRemoveFailedToast(name: String, reason: String) -> ToastContent {
        ToastContent(variant: .warning, title: "Couldn't remove \(name)", message: reason)
    }

    static func reorderToolFloatsFailedToast(reason: String) -> ToastContent {
        ToastContent(
            variant: .warning, title: "Couldn't reorder tool floats",
            message: "Failed to update the config file: \(reason)")
    }

    static func reorderWorkspacesFailedToast(reason: String) -> ToastContent {
        ToastContent(
            variant: .warning, title: "Couldn't reorder workspaces",
            message: "Failed to update the workspaces file: \(reason)")
    }

    static let claudeSetUpToast = ToastContent(
        variant: .positive, title: "Claude Code can use zen", message: "New Claude sessions load the zen skill.")

    static let claudeUpdatedToast = ToastContent(
        variant: .info, title: "Updated zen for Claude Code", message: "New Claude sessions load it.")

    static func claudeSetupFailureToast(title: String, reason: String) -> ToastContent {
        ToastContent(variant: .warning, title: title, message: reason)
    }

    static func nothingWaitingToast(elsewhere: Bool) -> ToastContent {
        ToastContent(
            variant: .info,
            title: elsewhere ? "Waiting in another window" : "Nothing is waiting",
            message: elsewhere
                ? "An agent is waiting in another window."
                : "No agent in this window is asking for you.\nThe sidebar lists the ones that are.")
    }

    static func worktreeRemovedToast(name: String) -> ToastContent {
        ToastContent(variant: .warning, title: "Worktree removed", message: "\(name) is no longer on disk.")
    }

    static func worktreeRemovedActions(close: @escaping () -> Void) -> [ToastAction] {
        [ToastAction(title: "Close workspace", kind: .primary, run: close)]
    }

    static func configDiagnosticsActions(
        dismiss: @escaping () -> Void, openSettings: @escaping () -> Void
    ) -> [ToastAction] {
        [
            ToastAction(title: "Dismiss", kind: .cancel, run: dismiss),
            ToastAction(title: "Open Settings", kind: .primary, run: openSettings),
        ]
    }

    static func conflictToast(_ conflict: KeybindConflict) -> ToastContent {
        ToastContent(variant: .warning, title: conflict.headline, message: conflict.message)
    }

    static func conflictActions(
        _ conflict: KeybindConflict, revert: @escaping () -> Void, accept: @escaping () -> Void
    ) -> [ToastAction] {
        var actions: [ToastAction] = []
        if conflict.isRevertable { actions.append(ToastAction(title: "Revert", kind: .cancel, run: revert)) }
        if conflict.isAcceptable { actions.append(ToastAction(title: "Accept", kind: .primary, run: accept)) }
        return actions
    }

    struct ClaudeSetupPrompt {
        let title: String
        let message: String
        let confirm: String
        let decline: String

        var content: ToastContent { ToastContent(variant: .info, title: title, message: message) }

        func actions(confirmed: @escaping () -> Void, declined: @escaping () -> Void) -> [ToastAction] {
            [
                ToastAction(title: confirm, kind: .primary, run: confirmed),
                ToastAction(title: decline, kind: .cancel, run: declined),
            ]
        }
    }

    static func claudeSetupOffer(in folder: String) -> ClaudeSetupPrompt {
        ClaudeSetupPrompt(
            title: "Teach Claude Code to use zen?", message: claudeSetupOfferMessage(in: folder),
            confirm: "Set up", decline: "Don't ask again")
    }

    static let claudeUpdateOffer = ClaudeSetupPrompt(
        title: "Update zen for Claude Code?", message: claudeUpdateOfferMessage, confirm: "Update",
        decline: "Skip this version")

    static let surfaceFailureToast = ToastContent(
        variant: .warning, title: "Terminal didn't start", message: "The terminal surface failed to launch.")

    static func surfaceFailureActions(close: @escaping () -> Void, retry: @escaping () -> Void) -> [ToastAction] {
        [
            ToastAction(title: "Close pane", kind: .destructive, run: close),
            ToastAction(title: "Retry", kind: .primary, run: retry),
        ]
    }

    static func waitingCardToast(title: String, titleTail: String?, message: String) -> ToastContent {
        ToastContent(variant: .info, title: title, titleTail: titleTail, message: message, icon: "bell.fill")
    }

    static func completedCardToast(
        _ variant: ToastVariant, title: String, titleTail: String?, message: String
    ) -> ToastContent {
        ToastContent(variant: variant, title: title, titleTail: titleTail, message: message)
    }

    static func attentionCardActions(
        shortcut: @escaping () -> String, dismiss: @escaping () -> Void, open: @escaping () -> Void
    ) -> [ToastAction] {
        [
            ToastAction(title: "Dismiss", kind: .cancel, run: dismiss),
            ToastAction(title: "Switch", kind: .primary, shortcut: shortcut, run: open),
        ]
    }
}
