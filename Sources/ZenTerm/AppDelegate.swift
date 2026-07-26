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

    /// The app-global `.configDidChange` re-apply, held in its own type so it's testable (ZEN-281).
    /// Lazy because the sinks reach back through `self`; every one resolves its collaborator at
    /// call time, so building this before `updateController` exists is fine.
    private lazy var configApplier = ConfigApplier(
        sinks: ConfigApplier.Sinks(
            setKeymap: { [weak self] map in self?.keys.setKeymap(map) },
            applyMotion: { MotionConfig.apply($0) },
            announceDiagnostics: { [weak self] content, scope in
                guard let self, let controller = self.keyController() else { return false }
                // Replace any earlier config notice only once we're sure a window can take the new one.
                self.windows.forEach { $0.dismissConfigDiagnosticsToast() }
                controller.showConfigDiagnosticsToast(content, landingScope: scope)
                return true
            },
            // Every window, not just the key one: the notice was delivered to whichever window was
            // key at the time, which need not be the one in front now.
            retractDiagnostics: { [weak self] in
                self?.windows.forEach { $0.dismissConfigDiagnosticsToast() }
            },
            reapplyUpdateCardTheme: { [weak self] in self?.updateController?.reapplyTheme() },
            applyAutoCheckSetting: { [weak self] in self?.updateController?.applyAutoCheckSetting() }))

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
        // hand-edited their config and quit has no reason to open Settings — they're exactly who this
        // is for. It also seeds the change-gate, so a pre-existing problem can't ambush them later,
        // attached to an unrelated edit that didn't cause it.
        configApplier.surfaceConfigDiagnostics()

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

        // Re-apply the app-global half of a config change: the interceptor's keymap, reduce-motion,
        // the config-problems notice, and the update card. Which blocks run is `ConfigApplier`'s
        // call, where it can be tested against the ungated fan-out (ZEN-281).
        NotificationCenter.default.addObserver(
            forName: .configDidChange, object: nil, queue: .main
        ) { [weak self] note in
            self?.configApplier.apply(ConfigChange.from(note))
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
            // Forced: ⌘⌥R is the "make the app match my config" escape hatch, so it re-applies
            // everything rather than only what the diff says moved.
            AppConfig.reload(force: true)
            return
        }
        if case .checkForUpdates = chord {
            // App-global: the updater is app-owned, not window-scoped. Nil means an unpackaged
            // build, where there's no updater at all — say so rather than swallowing the command.
            guard let updateController else {
                keyController()?.showToast(UpdateController.inertNotice)
                return
            }
            updateController.checkForUpdates()
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

    /// Copy/Paste forwarders reached via the responder chain (menu items have a nil target) — always
    /// act on the key window's controller, never a stale one. The modal-aware routing (paste into a
    /// card's focused field vs the surface) lives in `WindowController`: as the window delegate it's
    /// reached ahead of this app-delegate fallback, so duplicating the guard here would be dead code.
    @objc func copyFromSurface(_ sender: Any?) {
        keyController()?.copyFromSurface(sender)
    }
    @objc func pasteToSurface(_ sender: Any?) {
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

    /// Export a diagnostics zip (logs + system metadata) via a save panel. Reached from Help ▸ Export
    /// Diagnostics with a nil target, routed here through the responder chain like About; ZEN-212's
    /// in-app report reuses the same action.
    @objc func exportDiagnostics(_ sender: Any?) {
        keyController()?.exportDiagnostics()
    }

    /// Opens the "Report an Issue" composer. Reached from Help ▸ Report an Issue with a nil target,
    /// routed here through the responder chain like About; the Settings nav button opens the same card.
    @objc func reportAnIssue(_ sender: Any?) {
        keyController()?.openReportIssue()
    }

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
