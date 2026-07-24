import AppKit
import AppLog
import Sparkle

/// Owns the Sparkle updater and the one app-global update card (ZEN-118). Built and started by
/// `AppDelegate` at launch. The card is app-global, not window-scoped: it presents into the key
/// window's toast stack and re-homes to the next key window if that window closes mid-flow, so a
/// download is never stranded by a closed window.
final class UpdateController {
    /// Only a packaged build carries `SUFeedURL`; a `swift run` dev build has none. Gate on it so
    /// the updater stays fully inert in dev — an installed app and a dev build run side by side
    /// daily (ZEN-116), and this mirrors the reasoning in `AppVersion.current`'s `0.0.0+src` fallback.
    static var isSupported: Bool {
        Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil
    }

    private let updater: SPUUpdater
    private let driver: ZenUpdateDriver
    private let keyController: () -> WindowController?

    /// True once `updater.start()` has returned successfully. The manual check and the auto-check
    /// setting reach into `SPUUpdater`, which requires a started updater — `isSupported` only means a
    /// feed URL exists, so a packaged build whose `start()` threw (a malformed Sparkle plist) would
    /// still be `isSupported` while the updater is unusable. Gate on this, not `isSupported`.
    private var started = false

    private var state: UpdateCardView.State?
    private var actions = UpdateCardView.Actions()
    private var card: UpdateCardView?
    private weak var host: WindowController?
    private var windowCloseObserver: NSObjectProtocol?

    /// - Parameter keyController: resolves the `WindowController` that should host the card right
    ///   now (the key window's, falling back to the first). Supplied by `AppDelegate`, which keeps
    ///   `keyController()` private.
    init(keyController: @escaping () -> WindowController?) {
        self.keyController = keyController
        let driver = ZenUpdateDriver()
        self.driver = driver
        self.updater = SPUUpdater(
            hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: nil)
        driver.controller = self
    }

    deinit {
        if let windowCloseObserver { NotificationCenter.default.removeObserver(windowCloseObserver) }
    }

    /// Start scheduled update checks. A no-op in an unpackaged build. Safe to call once at launch.
    func start() {
        guard Self.isSupported else {
            Log.info("update checks inert — unpackaged build (no feed URL)", category: .update)
            return
        }
        do {
            try updater.start()
        } catch {
            Log.warning(
                "ZenTerm: update checks unavailable — \(error.localizedDescription)", category: .update)
            return
        }
        started = true
        Log.info(
            "update checks live (auto-check \(GeneralConfig.current.automaticUpdateChecks ? "on" : "off"))",
            category: .update)
        applyAutoCheckSetting()
        windowCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { [weak self] note in
            self?.hostWindowMaybeClosing(note.object as? NSWindow)
        }
    }

    /// Point Sparkle's automatic-check schedule at the config's off switch (ZEN-19). The packaged
    /// plist enables checks by default; this makes the config the source of truth. Called at
    /// launch and re-applied by `AppDelegate` on `.configDidChange`, so a Settings toggle takes
    /// effect with no relaunch. Inert in an unpackaged build.
    func applyAutoCheckSetting() {
        guard started else { return }
        updater.automaticallyChecksForUpdates = GeneralConfig.current.automaticUpdateChecks
    }

    /// Run a user-initiated check now (the "Check for Updates" command, ZEN-20). Unlike a scheduled
    /// check, the driver reports its result even when nothing's found. A no-op in an unpackaged build.
    func checkForUpdates() {
        guard started else { return }
        updater.checkForUpdates()
    }

    /// Surface a toast from the driver (a user-initiated check's up-to-date / failure result). Routed
    /// to the key window, like the card. `keyController()` falls back to the first window when none is
    /// key, so this only drops silently when the key window belongs to something that isn't one of
    /// ours (an open panel) or no window is open — the same resolver the card uses.
    func announce(_ content: ToastContent) {
        keyController()?.showToast(content)
    }

    // MARK: - Card presentation (called by the driver)

    /// Show or morph the card to `state`. Called on the main thread by `ZenUpdateDriver` as Sparkle
    /// drives the flow; repeated calls with the same host morph the live card in place.
    func present(state: UpdateCardView.State, actions: UpdateCardView.Actions) {
        dispatchPrecondition(condition: .onQueue(.main))
        self.state = state
        self.actions = actions
        render()
    }

    /// Tear the card down and return to no-card. Idempotent.
    func dismiss() {
        dispatchPrecondition(condition: .onQueue(.main))
        state = nil
        render()
    }

    /// Recolor a live card after a config change — it can be up across a theme swap, and it lives
    /// outside any window's toast list, so `AppDelegate` drives this from `.configDidChange`.
    func reapplyTheme() {
        card?.reapplyTheme()
    }

    private func render() {
        guard let state else {
            if let card, let host {
                host.dismissUpdateCard(card)
                Log.info("update card torn down", category: .update)
            }
            card = nil
            host = nil
            return
        }
        // A card already showing in a live host morphs in place — and must do so even when
        // `keyController()` can't resolve a host right now. A foreign key window (an open save/open
        // panel, or another app frontmost) makes `keyController()` nil; gating this morph on it is
        // what stranded the card on a stale state whose `fireOnce` reply had already fired, so
        // Later / Relaunch did nothing and the card couldn't be dismissed (ZEN-248). Re-homing to a
        // *closed* host is handled by `hostWindowMaybeClosing`, which nils `host` first — so a
        // non-nil `host` here always means a live window still showing this card. Not gating on the
        // key window also matches the card's documented intent: it re-homes only when its host
        // *closes* mid-flow, not as focus wanders between windows.
        if let card, host != nil {
            card.update(to: state, actions: actions)
            Log.info("update card morphed in place: \(state.logLabel)", category: .update)
            return
        }
        guard let controller = keyController() else {
            // The leading candidate from ZEN-248, which previously left no trace: distinguish the two
            // `keyController()` failure modes — no key window at all vs. a foreign one (an open save/
            // open panel, or another app frontmost).
            let keyState = NSApp.keyWindow == nil ? "no key window" : "foreign key window"
            Log.warning(
                "update card dropped — no host to show it (\(keyState)); retries on next state",
                category: .update)
            return
        }
        let fresh = UpdateCardView(state: state, actions: actions)
        controller.presentUpdateCard(fresh)
        card = fresh
        host = controller
        Log.info("update card presented: \(state.logLabel)", category: .update)
    }

    /// The hosting window is closing. Drop the card (it dies with that window's view tree) and
    /// re-present into whatever becomes key. `willClose` fires before key moves, so hop a tick.
    private func hostWindowMaybeClosing(_ window: NSWindow?) {
        guard state != nil, let host, window === host.window else { return }
        Log.info("update card host window closing — re-homing on next render", category: .update)
        card = nil
        self.host = nil
        DispatchQueue.main.async { [weak self] in self?.render() }
    }
}
