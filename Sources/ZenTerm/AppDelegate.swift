import AppKit
import AppLog
import TabKit

/// Owns every window and routes chords/Copy/Paste to whichever is key. `⌘n` opens a
/// new window (inheriting the key window's focused-pane cwd); every other chord goes
/// to the key window's `WindowController`. Native macOS tabbing is disallowed on
/// `HostWindow`, so each window is an ordinary independently-tileable window.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windows: [WindowController] = []
    private let keys = KeyInterceptor()
    /// The nvim navigator command socket (`$ZEN_SOCK`). Started at launch, torn down on
    /// quit. Nil if it couldn't bind — the ⌘-nav path never depends on it.
    private var navSocket: NavSocketServer?
    /// True between a ⌘Q that raised the quit confirm and its reply, so a second ⌘Q can't
    /// stack a second quit dialog — while a non-quit (close-pane) confirm never blocks ⌘Q.
    private var quitConfirmPending = false
    /// In-app auto-updates (ZEN-118). Nil in an unpackaged dev build, where the updater is inert.
    private var updateController: UpdateController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Install the on-disk log sink now that this is a real app run, before the first config
        // load logs anything. Left nil under `swift test` (the app never launches there), so a test
        // run never writes to the user's ~/Library/Logs/ZenTerm/zen-term.log.
        Log.fileSink = .standard()

        // Terminals repeat a held key rather than popping macOS's press-and-hold accent
        // palette — the palette otherwise leaks the auto-repeats and the selection number
        // key straight into the shell. Match ghostty and every other terminal: disable it
        // so a held key auto-repeats. Must be registered before the first surface exists.
        UserDefaults.standard.register(defaults: ["ApplePressAndHoldEnabled": false])

        // Resolve the general config before any window builds — installing the reduce-motion
        // override and deterministically forcing GeneralConfig.current to load (so the first
        // window's Theme font, drawer sizes, and dock floats are already settled).
        MotionConfig.apply(GeneralConfig.current.reduceMotion)

        // Verbose diagnostics gate (ZEN-11): config `debug = true` turns on the same file tee as
        // ZENTERM_LOG_VERBOSE=1 (already seeded into Log.isVerbose), so either switch enables it.
        if GeneralConfig.current.debug { Log.isVerbose = true }
        Log.info("ZenTerm launched v\(AppVersion.current)", category: .app)

        MainMenu.install(copyPaste: nil)  // Copy/Paste route via the responder chain
        newWindow(initialCWD: nil, centered: true)
        // Announce a config that's already broken at launch, not just one broken later. Someone who
        // hand-edited their config and quit has no reason to open Settings → Keybinds — they're
        // exactly who this is for. It also seeds the change-gate, so a pre-existing conflict can't
        // ambush them later, attached to an unrelated edit that didn't cause it.
        surfaceKeymapDiagnostics()

        keys.onReservedChord = { [weak self] chord in self?.route(chord) }
        // Seamless-nav opt-in: let a `Ctrl`-nav chord fall through to a pane running nvim so
        // nvim moves its own splits. `⌘`-nav (the default) is never passed through, so default
        // pane nav is untouched whether or not the pane is nvim.
        keys.passThroughGuard = { [weak self] chord, action in
            NavGuard.shouldPassThrough(
                chord: chord, action: action,
                focusedPaneIsVim: self?.keyController()?.focusedPaneIsVim == true)
        }
        keys.setKeymap(GeneralConfig.current.keymap)
        keys.start()

        // The nvim navigator command socket. `apply` runs on the main thread (the server
        // hops decoded commands there), so it touches `NavRegistry` safely.
        let socket = NavSocketServer { command in
            switch command {
            case .focus(let token, let dir): NavRegistry.shared.route(focus: token, dir)
            case .setVim(let token, let on): NavRegistry.shared.setVim(token: token, on)
            }
        }
        socket.start()
        navSocket = socket

        // Agent OS-notifications: become the notification-center delegate (never prompts — only the
        // lazy `requestAuthorization` on first delivery does) and route banner clicks back to the tab.
        AgentNotifier.shared.installDelegate()
        AgentNotifier.shared.onActivate = { [weak self] windowID, tabID in
            self?.activateTab(windowID: windowID, tabID: tabID)
        }

        // The "fire for any tab when unfocused" path can leave a banner for a tab that's already
        // frontmost — its `clearWaiting` never fires (the active tab is never re-selected). Reactivating
        // means the user is now looking at it, so clear each window's active-tab banner.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.windows.forEach { $0.clearActiveTabNotification() }
        }

        // The one live consumer in PR1: when config changes (a keybind edit in the Settings card),
        // rebuild the interceptor's keymap so the rebind takes effect with no relaunch.
        NotificationCenter.default.addObserver(
            forName: .configDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            self?.keys.setKeymap(GeneralConfig.current.keymap)
            MotionConfig.apply(GeneralConfig.current.reduceMotion)  // re-install the reduce-motion override
            self?.surfaceKeymapDiagnostics()
            self?.updateController?.reapplyTheme()  // recolor a live update card — it's outside any window's toast list
            self?.updateController?.applyAutoCheckSetting()  // pick up a flipped auto-update toggle with no relaunch
        }

        // Auto-updates (ZEN-118). Inert in an unpackaged dev build (no SUFeedURL). The card is
        // app-global, so hand the updater a resolver for the current key window's controller.
        if UpdateController.isSupported {
            let controller = UpdateController(keyController: { [weak self] in self?.keyController() })
            controller.start()
            updateController = controller
        }

        NSApp.activate(ignoringOtherApps: true)
    }

    /// Route a chord: `⌘n` makes a new window, `.reloadConfig` re-reads config + theme from
    /// disk, `.checkForUpdates` runs a manual update check — all app-global, not window-scoped;
    /// everything else goes to the key window's controller. The palette also lands here for the
    /// app-global chords, via `WindowController.onAppGlobalCommand` (they're a no-op in `handle`).
    private func route(_ chord: KeyInterceptor.ReservedChord) {
        if case .newWindow = chord {
            // ⌘N is intercepted here before `handle(_:)`, so a palette's / confirm's modal
            // gate doesn't cover it — swallow it explicitly while either is open.
            if let key = keyController(), key.isModalOverlayOpen || key.isConfirmOpen { return }
            newWindow(initialCWD: keyController()?.focusedCWD, centered: false)
            return
        }
        if case .reloadConfig = chord {
            AppConfig.reload()
            return
        }
        if case .checkForUpdates = chord {
            updateController?.checkForUpdates()  // app-global: the updater is app-owned, not window-scoped
            return
        }
        keyController()?.handle(chord)
    }

    /// A banner was clicked: bring the app forward and jump to its originating tab. Routes by
    /// `windowID` (tab ids aren't unique across windows), then `selectTab` — a no-op if the tab or
    /// window has since closed.
    private func activateTab(windowID: Int, tabID: TabID) {
        guard let wc = windows.first(where: { $0.windowID == windowID }) else { return }
        NSApp.activate(ignoringOtherApps: true)
        wc.window.makeKeyAndOrderFront(nil)
        wc.selectTab(tabID)
    }

    /// The keymap problems announced on the last reload — so an unchanged set stays quiet.
    private var lastKeymapDiagnostics: [ConfigDiagnostic] = []

    /// Toast the config's keybind problems when they change. Lives here, not in `WindowController`:
    /// that observer runs once per open window, so three windows would mean three toasts for one
    /// reload — and the keymap these describe is app-global anyway. Routed to the key window only.
    /// The decision itself is `ConfigDiagnostic.announcement`, where it's testable.
    private func surfaceKeymapDiagnostics() {
        let diagnostics = GeneralConfig.current.keymapDiagnostics
        guard
            let content = ConfigDiagnostic.announcement(
                for: diagnostics, alreadyAnnounced: lastKeymapDiagnostics)
        else {
            lastKeymapDiagnostics = diagnostics
            return
        }
        // Record it as announced only once a window has actually shown it. `keyController()` is nil
        // when the key window isn't one of ours (an open panel), and marking an undelivered notice
        // as announced would let the change-gate swallow it forever.
        guard let controller = keyController() else { return }
        controller.showToast(content)
        lastKeymapDiagnostics = diagnostics
    }

    /// The `WindowController` owning the current key window, falling back to the
    /// first window (e.g. before any window has become key).
    private func keyController() -> WindowController? {
        guard let key = NSApp.keyWindow else { return windows.first }
        return windows.first { $0.window === key }
    }

    private func newWindow(initialCWD: URL?, centered: Bool) {
        let offset = CGFloat(windows.count) * 28
        let rect = NSRect(x: 0, y: 0, width: 900, height: 560).offsetBy(dx: offset, dy: -offset)
        let wc = WindowController(contentRect: rect, initialCWD: initialCWD)
        wc.keybindCapturer = keys
        // The command palette dispatches through `handle(_:)`, where app-global chords are a no-op.
        // Hand them back to `route(_:)` so a palette pick reloads config / checks for updates too.
        wc.onAppGlobalCommand = { [weak self] chord in self?.route(chord) }
        if centered { wc.window.center() }
        wc.onClosed = { [weak self, weak wc] in
            guard let self, let wc else { return }
            self.windows.removeAll { $0 === wc }
        }
        windows.append(wc)
        wc.showAndStart()
    }

    /// Copy/Paste forwarders reached via the responder chain (menu items have a nil
    /// target) — always act on the key window's active tab, never a stale window.
    @objc func copyFromSurface(_ sender: Any?) {
        if isConfirmModal { return }  // confirm has no text field
        if isModalUp {
            NSApp.keyWindow?.firstResponder?.tryToPerform(#selector(NSText.copy(_:)), with: sender); return
        }
        keyController()?.copyFromSurface(sender)
    }
    @objc func pasteToSurface(_ sender: Any?) {
        if isConfirmModal { return }  // confirm has no text field
        if isModalUp {
            NSApp.keyWindow?.firstResponder?.tryToPerform(#selector(NSText.paste(_:)), with: sender); return
        }
        keyController()?.pasteToSurface(sender)
    }

    /// The standard About panel sources its version from `Info.plist` alone, so an unpackaged
    /// `swift run` build showed no version at all while the Settings footer read `0.0.0+src`. Hand
    /// it `AppVersion`, so both places agree on one string. The build number stays conditional:
    /// there's no honest fallback for it, and an empty one renders as a bare "()".
    @objc func showAbout(_ sender: Any?) {
        var options: [NSApplication.AboutPanelOptionKey: Any] = [.applicationVersion: AppVersion.current]
        if let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String {
            options[.version] = build
        }
        NSApp.orderFrontStandardAboutPanel(options: options)
    }

    /// Opens the third-party notices in their own window (`AcknowledgementsWindow`), reached from
    /// the app menu under About. A dedicated window rather than the About panel's credits: the full
    /// license text is a long read that reads as a wall of noise crammed into the About box.
    @objc func showAcknowledgements(_ sender: Any?) {
        AcknowledgementsWindow.shared.show()
    }

    /// While a modal overlay (a palette or the Add-Workspace form) is up, Copy/Paste must act on
    /// its focused text field, not the terminal hidden behind it (else ⌘V would inject the
    /// clipboard into that shell).
    private var isModalUp: Bool { keyController()?.isModalOverlayOpen == true }

    /// While a confirm toast is up it's fully modal — ⌘N and Copy/Paste are swallowed
    /// (it has no text field to act on), mirroring `isModalUp`.
    private var isConfirmModal: Bool { keyController()?.isConfirmOpen == true }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Remove the nav socket on quit so the next launch rebinds a fresh one. Fires after
    /// the quit is approved, covering every termination path.
    func applicationWillTerminate(_ notification: Notification) {
        navSocket?.stop()
    }

    /// ⌘Q always confirms: tally tabs across every window and gate on the key window's
    /// confirm toast. `.terminateLater` requires exactly one matching
    /// `reply(toApplicationShouldTerminate:)` — Quit replies `true`, Cancel replies
    /// `false` (via `presentQuitConfirm`'s `onCancel`), so the pending request never leaks.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let key = keyController() else { return .terminateNow }
        if quitConfirmPending { return .terminateCancel }  // a quit dialog is already up
        quitConfirmPending = true
        let tabCount = windows.reduce(0) { $0 + $1.tabCount }
        key.presentQuitConfirm(
            tabCount: tabCount, windowCount: windows.count,
            onQuit: { [weak self] in
                self?.quitConfirmPending = false
                NSApp.reply(toApplicationShouldTerminate: true)
            },
            onCancel: { [weak self] in
                self?.quitConfirmPending = false
                NSApp.reply(toApplicationShouldTerminate: false)
            })
        return .terminateLater
    }
}
