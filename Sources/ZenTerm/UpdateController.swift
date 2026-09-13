import AppKit
import AppLog
import Sparkle

@MainActor
final class UpdateController {
    /// Only a packaged build carries `SUFeedURL`, so the updater stays inert in a `swift run` build.
    static var isSupported: Bool {
        Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil
    }

    private let updater: SPUUpdater
    private let driver: ZenUpdateDriver
    private let keyController: () -> WindowController?

    /// `start()` can throw on a packaged build with a malformed Sparkle plist, which `isSupported` does not catch.
    private var started = false

    private var state: UpdateCardView.State?
    private var actions = UpdateCardView.Actions()
    private var card: UpdateCardView?
    private weak var host: WindowController?
    private var windowCloseObserver: NSObjectProtocol?

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
            MainActor.assumeIsolated { self?.hostWindowMaybeClosing(note.object as? NSWindow) }
        }
    }

    func applyAutoCheckSetting() {
        guard started else { return }
        updater.automaticallyChecksForUpdates = GeneralConfig.current.automaticUpdateChecks
    }

    /// Two lines because each has to fit `ToastView.messageMaxWidth` on its own.
    static let inertNotice = ToastContent(
        variant: .info, title: "Updates are off in this build",
        message: "Run from source, so there's no feed.\nThe installed app updates itself.")

    func checkForUpdates() {
        guard started else {
            announce(
                ToastContent(
                    variant: .warning, title: "Couldn't check for updates",
                    message: "The updater didn't start. See the log for details."))
            return
        }
        updater.checkForUpdates()
    }

    func announce(_ content: ToastContent) {
        keyController()?.showToast(content)
    }

    func present(state: UpdateCardView.State, actions: UpdateCardView.Actions) {
        dispatchPrecondition(condition: .onQueue(.main))
        self.state = state
        self.actions = actions
        render()
    }

    func dismiss() {
        dispatchPrecondition(condition: .onQueue(.main))
        state = nil
        render()
    }

    func reapplyTheme() {
        card?.reapplyTheme()
    }

    /// Morphs a live card even when `keyController()` is nil: a foreign key window would strand it with spent replies.
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
        if let card, host != nil {
            card.update(to: state, actions: actions)
            Log.info("update card morphed in place: \(state.logLabel)", category: .update)
            return
        }
        guard let controller = keyController() else {
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

    /// `willClose` fires before key moves, so re-presenting hops a tick.
    private func hostWindowMaybeClosing(_ window: NSWindow?) {
        guard state != nil, let host, window === host.window else { return }
        Log.info("update card host window closing — re-homing on next render", category: .update)
        card = nil
        self.host = nil
        DispatchQueue.main.async { [weak self] in self?.render() }
    }
}
