import AppKit
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
        guard Self.isSupported else { return }
        do {
            try updater.start()
        } catch {
            NSLog("ZenTerm: update checks unavailable — \(error.localizedDescription)")
            return
        }
        windowCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { [weak self] note in
            self?.hostWindowMaybeClosing(note.object as? NSWindow)
        }
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
            if let card, let host { host.dismissUpdateCard(card) }
            card = nil
            host = nil
            return
        }
        guard let controller = keyController() else { return }  // nothing to host it; re-home on close

        if let card, host === controller {
            card.update(to: state, actions: actions)  // morph in place
            return
        }
        if let card, let host { host.dismissUpdateCard(card) }
        let fresh = UpdateCardView(state: state, actions: actions)
        controller.presentUpdateCard(fresh)
        card = fresh
        host = controller
    }

    /// The hosting window is closing. Drop the card (it dies with that window's view tree) and
    /// re-present into whatever becomes key. `willClose` fires before key moves, so hop a tick.
    private func hostWindowMaybeClosing(_ window: NSWindow?) {
        guard state != nil, let host, window === host.window else { return }
        card = nil
        self.host = nil
        DispatchQueue.main.async { [weak self] in self?.render() }
    }
}
