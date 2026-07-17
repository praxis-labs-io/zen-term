#if DEBUG
    import AppKit

    /// TEMPORARY dev preview of the update card (ZEN-118) — DEBUG-only, env-gated, removed before this
    /// ships. Drives the card through its three states in a real window via the real `UpdateController`
    /// present path, without the Sparkle appcast plumbing, so the card can be eyeballed in a dev build.
    ///
    /// Run: `ZEN_UPDATE_PREVIEW=1 swift run ZenTerm`
    /// Then: Install → a simulated download ramp → Ready; Later/Skip/Relaunch dismiss it.
    enum UpdateCardPreview {
        private static var controller: UpdateController?
        private static var timer: Timer?

        static func start(keyController: @escaping () -> WindowController?) {
            let controller = UpdateController(keyController: keyController)
            self.controller = controller
            showAvailable()
        }

        private static func showAvailable() {
            var actions = UpdateCardView.Actions()
            actions.install = { simulateDownload() }
            actions.later = { controller?.dismiss() }
            actions.skip = { controller?.dismiss() }
            actions.whatsNew = { NSWorkspace.shared.open($0) }
            controller?.present(
                state: .available(
                    version: "0.2.0",
                    current: "You're on 0.1.4",
                    notes: [
                        "Faster cold start",
                        "Fixes the ⌥-arrow reorder that did nothing",
                        "In-app updates, themed to match your terminal",
                    ],
                    notesURL: URL(string: "https://github.com/zen-term/zen-term-releases/releases/latest")),
                actions: actions)
        }

        private static func simulateDownload() {
            var progress = 0.0
            timer?.invalidate()
            controller?.present(state: .downloading(fraction: 0), actions: .init())
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { tick in
                progress += 0.06
                if progress >= 1 {
                    tick.invalidate()
                    showReady()
                } else {
                    controller?.present(state: .downloading(fraction: progress), actions: .init())
                }
            }
        }

        private static func showReady() {
            var actions = UpdateCardView.Actions()
            actions.relaunch = { controller?.dismiss() }
            actions.later = { controller?.dismiss() }
            controller?.present(state: .ready(version: "0.2.0"), actions: actions)
        }
    }
#endif
