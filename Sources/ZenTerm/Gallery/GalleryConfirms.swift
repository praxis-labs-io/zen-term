#if DEBUG
    import AppKit

    enum GalleryConfirms {
        private static let running = ["claude", "npm run dev"]

        static func sections() -> [GallerySection] {
            [
                section(
                    "Confirm cards: closing",
                    [
                        ("Pane", CloseWarning.prompt(closing: .pane, naming: [])),
                        ("Drawer", CloseWarning.prompt(closing: .drawer, naming: [])),
                        ("Tab", CloseWarning.prompt(closing: .tab, naming: running)),
                        ("Workspace", CloseWarning.prompt(closing: .workspace("zen-term"), naming: running)),
                        ("Window", CloseWarning.prompt(closing: .window, naming: running, closingOtherWindows: 1)),
                        ("Last pane", CloseWarning.prompt(closing: .lastPane(running: false), naming: [])),
                        ("Last pane, running", CloseWarning.prompt(closing: .lastPane(running: true), naming: running)),
                        ("Last tab", CloseWarning.prompt(closing: .lastTab(running: false), naming: [])),
                        ("Last tab, running", CloseWarning.prompt(closing: .lastTab(running: true), naming: running)),
                        ("Last workspace", CloseWarning.prompt(closing: .lastWorkspace(running: false), naming: [])),
                        (
                            "Last workspace, running",
                            CloseWarning.prompt(closing: .lastWorkspace(running: true), naming: running)
                        ),
                        (
                            "Login pane",
                            CloseWarning.prompt(closing: .login(host: "devbox", closing: .pane), naming: [])
                        ),
                        (
                            "Login drawer",
                            CloseWarning.prompt(closing: .login(host: "devbox", closing: .drawer), naming: [])
                        ),
                        ("Login tab", CloseWarning.prompt(closing: .login(host: "devbox", closing: .tab), naming: [])),
                        ("Quit, one tab", CloseWarning.quit(tabCount: 1, windowCount: 1)),
                        ("Quit, tabs", CloseWarning.quit(tabCount: 4, windowCount: 1)),
                        ("Quit, windows", CloseWarning.quit(tabCount: 6, windowCount: 2)),
                    ]),
                section(
                    "Confirm cards: deleting",
                    [
                        ("Workspace", WorkspaceFormOverlay.deletePrompt(named: "zen-term")),
                        ("Tool float", ToolFloatFormOverlay.deletePrompt(named: "Scratch")),
                        ("SSH host", AddSSHHostOverlay.removePrompt(named: "devbox", session: nil)),
                        ("SSH host, connected", AddSSHHostOverlay.removePrompt(named: "devbox", session: .connected)),
                        (
                            "SSH host, connecting",
                            AddSSHHostOverlay.removePrompt(named: "devbox", session: .connecting)
                        ),
                        ("Worktree", worktreePrompt()),
                        ("Unsaved changes", .unsavedChanges),
                    ]),
            ]
        }

        private static func section(_ title: String, _ prompts: [(String, ConfirmPrompt)]) -> GallerySection {
            GallerySection(
                title: title,
                rows: prompts.map { label, prompt in GallerySection.Row(label: label, samples: [card(prompt)]) })
        }

        private static func worktreePrompt() -> ConfirmPrompt {
            WorktreeRemovalMessage.prompt(
                for: Worktree(
                    path: URL(fileURLWithPath: "/tmp/zen-term/feature-one"), branch: "feature/one", head: "4f2c9a1",
                    isLocked: false),
                state: WorktreeState(
                    files: [
                        WorktreeFileChange(path: "Sources/App.swift", categories: [.modified]),
                        WorktreeFileChange(path: "notes.md", categories: [.untracked]),
                    ],
                    lostCommits: 1),
                carried: [".env"], closes: ClosedByRemoval(workspaces: ["zen-term: feature/one"], stopping: ["claude"]))
        }

        // The shell is full-bleed; the low-priority hug shrinks it onto the card it centers.
        private static func card(_ prompt: ConfirmPrompt) -> NSView {
            let shell = ConfirmCard(prompt, onCancel: {}, onConfirm: {})
            for hug in [
                shell.widthAnchor.constraint(equalTo: shell.card.widthAnchor),
                shell.heightAnchor.constraint(equalTo: shell.card.heightAnchor),
            ] {
                hug.priority = .defaultLow
                hug.isActive = true
            }
            return shell
        }
    }
#endif
