import AppKit
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Terminals repeat a held key rather than popping macOS's press-and-hold accent
        // palette — the palette otherwise leaks the auto-repeats and the selection number
        // key straight into the shell. Match ghostty and every other terminal: disable it
        // so a held key auto-repeats. Must be registered before the first surface exists.
        UserDefaults.standard.register(defaults: ["ApplePressAndHoldEnabled": false])

        // Resolve the general config before any window builds — installing the reduce-motion
        // override and deterministically forcing GeneralConfig.current to load (so the first
        // window's Theme font, drawer sizes, and dock floats are already settled).
        MotionConfig.apply(GeneralConfig.current.reduceMotion)

        MainMenu.install(copyPaste: nil)  // Copy/Paste route via the responder chain
        newWindow(initialCWD: nil, centered: true)

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
        }

        NSApp.activate(ignoringOtherApps: true)
    }

    /// Route a chord: `⌘n` makes a new window, `.reloadConfig` re-reads config + theme from
    /// disk (app-global, not window-scoped); everything else goes to the key window's
    /// controller.
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
