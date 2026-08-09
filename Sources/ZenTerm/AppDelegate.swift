import AppKit
import AppLog
import TabKit
import TerminalKit

/// Owns every window and routes chords/Copy/Paste to whichever is key. `⌘n` opens a
/// new window (inheriting the key window's focused-pane cwd); every other chord goes
/// to the key window's `WindowController`. Native macOS tabbing is disallowed on
/// `HostWindow`, so each window is an ordinary independently-tileable window.
@MainActor
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
            reportBackendShadow: { [weak self] in self?.reportBackendShadow() },
            applyMotion: { MotionConfig.apply($0) },
            announceDiagnostics: { [weak self] content, scope in
                guard let self else { return false }
                return WindowController.deliverConfigDiagnosticsNotice(
                    content, landingScope: scope, to: self.keyController(),
                    replacingAcross: self.windows)
            },
            // Every window, not just the key one: the notice was delivered to whichever window was
            // key at the time, which need not be the one in front now.
            retractDiagnostics: { [weak self] in
                self?.windows.forEach { $0.dismissConfigDiagnosticsToast() }
            },
            announceConflicts: { [weak self] conflicts in
                guard let self else { return false }
                return WindowController.deliverConflictNotices(
                    conflicts, to: self.keyController(), replacingAcross: self.windows)
            },
            retractConflicts: { [weak self] in
                self?.windows.forEach { $0.dismissConflictToasts() }
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

        // The menu must go up before the config load. Assembling the keymap reads `NSApp.mainMenu`
        // for the chords the menu owns (`MenuShortcuts`), and a nil menu there yields an empty
        // protected set, which is the guard silently not running.
        MainMenu.install()  // every item routes by selector, through the responder chain

        // Resolve the config and theme before any window builds, so the first window's font,
        // drawer sizes, and dock floats are already settled rather than built-in defaults. This is
        // the one place the load happens: both statics hold the built-in default until now
        // (ZEN-31), because the load is main-thread-only and a lazy one would run wherever the
        // first reader happened to touch it.
        AppConfig.loadAtLaunch()
        MotionConfig.apply(GeneralConfig.current.reduceMotion)

        // Verbose diagnostics gate (ZEN-11): config `debug = true` turns on the same file tee as
        // ZENTERM_LOG_VERBOSE=1 (already seeded into Log.isVerbose), so either switch enables it.
        if GeneralConfig.current.debug { Log.isVerbose = true }
        Log.info("ZenTerm launched v\(AppVersion.current)", category: .app)

        newWindow(initialCWD: nil, centered: true)
        reportBackendShadow()
        // Announce a config that's already broken at launch, not just one broken later. Someone who
        // hand-edited their config and quit has no reason to open Settings — they're exactly who this
        // is for. It also seeds the change-gate, so a pre-existing problem can't ambush them later,
        // attached to an unrelated edit that didn't cause it.
        configApplier.surfaceConfigNotices()

        keys.onReservedChord = { [weak self] chord in self?.route(chord) }
        // Let a `Ctrl`-nav chord fall through to the terminal that owns it: a pane running nvim
        // (the seamless-nav opt-in, so nvim moves its own splits), or an open tool float, which is
        // modal and would only swallow the chord (ZEN-270). `⌘`-nav (the default) is never passed
        // through, so default pane nav is untouched in every case.
        //
        // One `keyController()` lookup per keystroke, not one per input: this runs on the hot path
        // and the two readings must come from the same window regardless.
        keys.passThroughGuard = { [weak self] chord, action in
            // A text view holding the keyboard owns the ⌘⇧ arrows and the Return pair. ⌘A is not in
            // that set and is measured, not assumed: AppKit serves Select All from an Edit menu item,
            // not from `NSTextView`, so a guard here would hand the chord to nobody. ZEN-370 serves
            // it from the menu instead, and the keymap ships ⌘A to no one.
            // Asked first because it does not depend on the window lookup below.
            if TextEditingChords.owns(chord, firstResponder: NSApp.keyWindow?.firstResponder) {
                return true
            }
            let controller = self?.keyController()
            return NavGuard.shouldPassThrough(
                chord: chord, action: action,
                focusedPaneIsVim: controller?.focusedPaneIsVim == true,
                toolFloatIsOpen: controller?.isToolFloatOpen == true)
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
        // frontmost — its `clearAttention` never fires (the active tab is never re-selected). Reactivating
        // means the user is now looking at it, so clear each window's active-tab banner.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // `queue: .main` guarantees this lands on the main thread; assert that rather than hop,
            // so the clear happens in the same turn as the activation.
            MainActor.assumeIsolated { self?.windows.forEach { $0.clearActiveTabNotification() } }
        }

        // Re-apply the app-global half of a config change: the interceptor's keymap, reduce-motion,
        // the config-problems notice, and the update card. Which blocks run is `ConfigApplier`'s
        // call, where it can be tested against the ungated fan-out (ZEN-281).
        NotificationCenter.default.addObserver(
            forName: .configDidChange, object: nil, queue: .main
        ) { [weak self] note in
            // `queue: .main`, so this is already the main thread — assert it rather than hop.
            MainActor.assumeIsolated { self?.configApplier.apply(ConfigChange.from(note)) }
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
    /// disk, `.checkForUpdates` runs a manual update check, and the three font-size chords resize
    /// every terminal surface the app owns — all app-global, not window-scoped; everything else goes
    /// to the key window's controller. The palette also lands here for the app-global chords, via
    /// `WindowController.onAppGlobalCommand` (they're a no-op in `handle`).
    private func route(_ chord: KeyInterceptor.ReservedChord) {
        if case .newWindow = chord {
            // ⌘N is intercepted here before `handle(_:)`, so a palette's / confirm's modal
            // gate doesn't cover it — swallow it explicitly while either is open.
            if let key = keyController(), key.isModalOverlayOpen || key.isConfirmOpen { return }
            newWindow(initialCWD: keyController()?.focusedCWD, centered: false)
            return
        }
        if case .reloadConfig = chord {
            // Forced: ⌘⇧, is the "make the app match my config" escape hatch, so it re-applies
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
        switch chord {
        case .increaseFontSize, .decreaseFontSize, .resetFontSize:
            // Same hand-rolled modal gate ⌘N uses, and for the same reason: these are intercepted
            // here, ahead of `handle(_:)`, so the gate cascade that would otherwise swallow them
            // while Settings, the palette or a confirm is up never runs. A palette *pick* still
            // works — `runCommand` closes the modal before it dispatches.
            if let key = keyController(), key.isModalOverlayOpen || key.isConfirmOpen { return }
            switch chord {
            case .increaseFontSize: applyFontSize { SessionFontSize.step(by: 1) }
            case .decreaseFontSize: applyFontSize { SessionFontSize.step(by: -1) }
            default: applyFontSize { SessionFontSize.reset() }
            }
        default: keyController()?.handle(chord)
        }
    }

    /// Move the session font size, then push it to every terminal surface the app owns and show
    /// where it landed.
    ///
    /// App-global on purpose (ZEN-224): libghostty binds these chords itself and applies each to the
    /// one focused surface, which is the bug. Every window, every tab, and every tool float gets the
    /// same size, and `SessionFontSize` also seeds surfaces spawned later — a pane split after a
    /// step has to open matched, or it has propagated no better than before.
    private func applyFontSize(_ move: () -> Void) {
        let before = SessionFontSize.points
        move()
        // Only re-push when it actually moved — but always show the card, including at a bound. The
        // card reports where the user stands, and standing at the floor is an answer; going silent
        // there reads as a dropped keystroke.
        if SessionFontSize.points != before {
            for window in windows { window.applySessionFontSize() }
        }
        keyController()?.showFontSize(SessionFontSize.display)
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

    /// Log what the config just handed to libghostty. Lives here rather than in the config load
    /// because it needs a live surface to ask through, which is why it is a load-time check and not
    /// a build-time one. Quiet when no window has a surface yet: the next reload asks again.
    private func reportBackendShadow() {
        guard let surface = windows.lazy.compactMap({ $0.anyTerminalSurface }).first else { return }
        BackendShadow.report(assembled: GeneralConfig.current.keymap, probe: surface.disposition)
    }

    private func newWindow(initialCWD: URL?, centered: Bool) {
        let offset = CGFloat(windows.count) * 28
        let rect = NSRect(x: 0, y: 0, width: 900, height: 560).offsetBy(dx: offset, dy: -offset)
        let wc = WindowController(contentRect: rect, initialCWD: initialCWD)
        wc.keybindCapturer = keys
        wc.keyModeHost = keys
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

    /// The Edit menu's forwarders, reached via the responder chain because the items have a nil
    /// target. Card and float routing lives in `WindowController`: as the window delegate it is
    /// reached ahead of this app-delegate fallback, so duplicating the guards here would be dead
    /// code.
    ///
    /// **Gated on a live key window, unlike the chord path.** `keyController` falls back to
    /// `windows.first` so a chord always lands somewhere, and that is wrong for these: the items are
    /// permanently enabled (nothing here implements `validateMenuItem:`), so with every window
    /// minimised a ⌘V would paste into a shell nobody can see, and a pasted newline runs it.
    private func editVerbTarget() -> WindowController? {
        guard NSApp.keyWindow != nil else { return nil }
        return keyController()
    }
    @objc func copy(_ sender: Any?) {
        editVerbTarget()?.copy(sender)
    }
    @objc func paste(_ sender: Any?) {
        editVerbTarget()?.paste(sender)
    }
    @objc func selectAll(_ sender: Any?) {
        editVerbTarget()?.selectAll(sender)
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

    /// Tear every window down, then wait for the session sweeps before letting the process go
    /// (ZEN-269). Without this, quit frees no surface at all: `windowWillClose` does not fire on
    /// termination, so the shells are orphaned and the kernel only hangs up each tty's foreground
    /// process group. `windows` is an Array, a value type, so iterating it is safe even though
    /// each teardown removes its own controller from it through `onClosed`.
    private func tearDownAllWindows(then completion: @escaping () -> Void) {
        for wc in windows { wc.tearDownForQuit() }
        drainSessionSweeps(then: completion)
    }

    /// Hold the quit open until every shell has gone and been swept.
    ///
    /// **Only correct after `tearDownForQuit()` has run on every window**, which is what makes it
    /// safe for the reaper to sweep a straggler whose leader is still alive: with no pane left,
    /// nothing it can reach is somebody's live work. The cap comes from the reaper rather than a
    /// literal, and bounds the graceful wait only: the sweep itself is always given its grace on
    /// top, so quit can never exit between the SIGTERM and the SIGKILL.
    private func drainSessionSweeps(then completion: @escaping () -> Void) {
        ShellSessionReaper.shared.drainForQuit(
            timeout: ShellSessionReaper.quitSweepBudget, completion: completion)
    }

    /// ⌘Q always confirms: tally tabs across every window and gate on the key window's
    /// confirm toast. `.terminateLater` requires exactly one matching
    /// `reply(toApplicationShouldTerminate:)` — Quit replies `true`, Cancel replies
    /// `false` (via `presentQuitConfirm`'s `onCancel`), so the pending request never leaks.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // No window left to confirm against, which is the path closing the LAST window takes:
        // `onClosed` has already emptied `windows`, so there is nothing to tear down and
        // nothing to ask. Its sweep is already in flight from `windowWillClose` though, and
        // exiting now would cut it off before a single signal went out — the original bug, on
        // the most ordinary way to close the app (ZEN-269). Wait for it, then go.
        guard let key = keyController() else {
            drainSessionSweeps { NSApp.reply(toApplicationShouldTerminate: true) }
            return .terminateLater
        }
        if quitConfirmPending { return .terminateCancel }  // a quit dialog is already up
        quitConfirmPending = true
        let tabCount = windows.reduce(0) { $0 + $1.tabCount }
        key.presentQuitConfirm(
            tabCount: tabCount, windowCount: windows.count,
            onQuit: { [weak self] in
                guard let self else {
                    NSApp.reply(toApplicationShouldTerminate: true)
                    return
                }
                self.quitConfirmPending = false
                self.tearDownAllWindows { NSApp.reply(toApplicationShouldTerminate: true) }
            },
            onCancel: { [weak self] in
                self?.quitConfirmPending = false
                NSApp.reply(toApplicationShouldTerminate: false)
            })
        return .terminateLater
    }

    #if DEBUG
        /// Test seam: build a window the way launch does, without the rest of
        /// `applicationDidFinishLaunching` (which binds the nav socket and starts the global
        /// key interceptor). Compiled out of release builds.
        func addWindowForTesting() { newWindow(initialCWD: nil, centered: false) }

        /// Test seam: the quit path's teardown, the half that was missing entirely.
        func quitTeardownForTesting(then completion: @escaping () -> Void) {
            tearDownAllWindows(then: completion)
        }
    #endif
}
