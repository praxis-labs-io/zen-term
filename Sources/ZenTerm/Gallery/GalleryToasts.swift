#if DEBUG
    import AppKit
    import TerminalKit

    @MainActor
    enum GalleryToasts {
        typealias Window = WindowController

        static func sections() -> [GallerySection] {
            [notices(), stickyCards(), attentionCards(), fontSize()]
        }

        private static func notices() -> GallerySection {
            let rows: [(String, [ToastContent])] = [
                (
                    "Diagnostics",
                    [
                        Window.diagnosticsExportedToast(file: "zenterm-diagnostics.zip"),
                        Window.diagnosticsExportFailedToast(reason: "You don't have permission to save in Desktop."),
                    ]
                ),
                (
                    "Float in the way",
                    [
                        Window.floatBlockedToast(isPane: false, name: "Lazygit"),
                        Window.floatBlockedToast(isPane: true, name: "review"),
                    ]
                ),
                (
                    "New worktree refused",
                    SidebarController.NewWorktreeRefusal.allCases.map(Window.newWorktreeRefusedToast)
                ),
                (
                    "Remote host",
                    [
                        Window.loginFailedToast(host: "devbox"),
                        Window.floatsStayLocalToast(host: "devbox"),
                    ]
                ),
                (
                    "Worktrees",
                    [
                        Window.newWorktreeMissingToast(name: "zen-term"),
                        Window.worktreeCreateFailedToast(reason: "A branch named feature/login already exists."),
                        Window.carryLostToast(".env is larger than 10 MB"),
                    ]
                ),
                (
                    "Workspaces",
                    [
                        Window.openInAnotherWindowToast(name: "zen-term"),
                        Window.worktreeRemoveFailedToast(name: "feature/login", reason: "The worktree is locked."),
                    ]
                ),
                (
                    "Reorder failed",
                    [
                        Window.reorderToolFloatsFailedToast(reason: "The file is read-only."),
                        Window.reorderWorkspacesFailedToast(reason: "The file is read-only."),
                    ]
                ),
                ("Claude Code", [Window.claudeSetUpToast, Window.claudeUpdatedToast]),
                (
                    "Agents",
                    [Window.nothingWaitingToast(elsewhere: false), Window.nothingWaitingToast(elsewhere: true)]
                ),
                ("Focus Mode", [TabController.zoomBlockedToast("split"), TabController.focusModeUnavailableToast]),
                ("Navigation", [TabController.noNeighborToast(.left, hint: nil)]),
                (
                    "Surfaces",
                    [
                        TabController.surfaceFailedToast(descriptor: "A pane"),
                        ToolFloatController.gitGuardToast(for: .scratch),
                    ]
                ),
                (
                    "Updates",
                    [
                        UpdateController.inertNotice, UpdateController.updaterDidNotStartNotice,
                        ZenUpdateDriver.upToDateNotice, ZenUpdateDriver.checkFailedNotice,
                    ]
                ),
            ]
            return GallerySection(
                title: "Toasts: notices",
                rows: rows.map { label, contents in
                    GallerySection.Row(label: label, samples: contents.map { ToastView(content: $0) })
                })
        }

        private static func stickyCards() -> GallerySection {
            let conflict = KeybindConflict(
                loser: .toggleZoom, chord: Chord(command: true, key: "⏎"), winner: .toggleSidebar)
            let diagnostics = [
                ConfigDiagnostic(
                    scope: .setting(key: "toast-duration"), problem: .invalidValue(got: "soon", expected: "seconds")),
                ConfigDiagnostic(
                    scope: .setting(key: "backdrop-alpha"), problem: .clamped(value: "1.4", to: "1")),
            ]
            let rows: [GallerySection.Row] = [
                row(
                    "Worktree removed", Window.worktreeRemovedToast(name: "feature/login"),
                    Window.worktreeRemovedActions {}, showsClose: true),
                GallerySection.Row(
                    label: "Config problems",
                    samples: [Array(diagnostics.prefix(1)), diagnostics].compactMap { list in
                        ConfigDiagnostic.toast(for: list).map {
                            sticky($0, Window.configDiagnosticsActions(dismiss: {}, openSettings: {}))
                        }
                    }),
                row(
                    "Shortcut conflict", Window.conflictToast(conflict),
                    Window.conflictActions(conflict, revert: {}, accept: {}), showsClose: true),
                GallerySection.Row(
                    label: "Claude Code offers",
                    samples: [Window.claudeSetupOffer(in: "~/.claude"), Window.claudeUpdateOffer].map {
                        sticky($0.content, $0.actions(confirmed: {}, declined: {}), showsClose: true)
                    }),
                row(
                    "Claude Code failed",
                    Window.setupFailureToast(
                        title: Window.updateFailedTitle, reason: "~/.claude/settings.json isn't valid JSON."),
                    [], showsClose: true),
                row(
                    "Surface failed", Window.surfaceFailureToast,
                    Window.surfaceFailureActions(close: {}, retry: {})),
            ]
            return GallerySection(title: "Toasts: sticky", rows: rows)
        }

        private static func attentionCards() -> GallerySection {
            let actions = Window.attentionCardActions(shortcut: { "⌘2" }, dismiss: {}, open: {})
            let results = [
                TerminalCommandResult(exitCode: 0, duration: 252), TerminalCommandResult(exitCode: 1, duration: 9),
            ]
            return GallerySection(
                title: "Toasts: attention and completion",
                rows: [
                    row(
                        "Waiting",
                        Window.waitingCardToast(
                            title: "zen-term", titleTail: ": right drawer", message: Window.turnEndMessage),
                        actions),
                    GallerySection.Row(
                        label: "Completed",
                        samples: results.map { result in
                            sticky(
                                Window.completedCardToast(
                                    result.exitCode == 0 ? .positive : .warning, title: "zen-term", titleTail: nil,
                                    message: Window.commandResultMessage(result)),
                                actions)
                        }),
                ])
        }

        private static func fontSize() -> GallerySection {
            GallerySection(
                title: "FontSizeCard",
                rows: [GallerySection.Row(label: "Readout", samples: [FontSizeCard(text: SessionFontSize.display)])])
        }

        private static func row(
            _ label: String, _ content: ToastContent, _ actions: [ToastAction], showsClose: Bool = false
        ) -> GallerySection.Row {
            GallerySection.Row(label: label, samples: [sticky(content, actions, showsClose: showsClose)])
        }

        private static func sticky(
            _ content: ToastContent, _ actions: [ToastAction], showsClose: Bool = false
        ) -> ToastView {
            ToastView(content: content, actions: actions, showsClose: showsClose)
        }
    }
#endif
