import AppKit
import Carbon.HIToolbox

/// Manages macOS secure keyboard entry (the Carbon `EnableSecureEventInput` API a terminal
/// engages at password prompts, so keystrokes can't be observed by other processes).
///
/// Secure input is **process-global and stateful**, which makes lifetime the whole problem:
/// every enable must be balanced by a disable, and — because it suppresses keyboard behavior
/// in *other* apps too — it has to be yielded while zen-term is inactive and reacquired on
/// reactivation. So a single surface toggling it on teardown isn't enough; we scope it to
/// focus and app-active state here. Mirrors Ghostty's own `SecureInput` manager.
final class SecureInput {
    static let shared = SecureInput()

    /// Per-surface desire keyed by object identity, valued by whether that surface is focused.
    /// Secure input is desired while any *focused* surface wants it — so a background pane at
    /// a password prompt doesn't hold the global lock over the pane you're actually typing in.
    private var scoped: [ObjectIdentifier: Bool] = [:]

    /// Whether we currently hold the global enable (mirrors the Carbon state we last set).
    private var isEnabled = false

    private var observers: [NSObjectProtocol] = []

    /// Injection seams so tests can assert the enable/disable balancing without touching the
    /// real process-global secure-input state (which would suppress input on the test machine).
    var enableHook: () -> OSStatus = { EnableSecureEventInput() }
    var disableHook: () -> OSStatus = { DisableSecureEventInput() }
    var isActiveHook: () -> Bool = { NSApp.isActive }

    private var isDesired: Bool { scoped.contains { $0.value } }

    init() {
        let center = NotificationCenter.default
        observers = [
            center.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in self?.apply() },
            center.addObserver(
                forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in self?.releaseWhileInactive() },
        ]
    }

    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }

    /// Record that `id` wants secure input and whether it's currently focused.
    func setScoped(_ id: ObjectIdentifier, focused: Bool) {
        scoped[id] = focused
        apply()
    }

    /// Drop `id`'s desire entirely (its surface no longer wants secure input, or is gone).
    func removeScoped(_ id: ObjectIdentifier) {
        scoped[id] = nil
        apply()
    }

    /// Converge the global state to what's desired. No-op while inactive — the active/resign
    /// observers own the lock across app-focus changes so we never hold it in the background.
    private func apply() {
        guard isActiveHook() else { return }
        guard isEnabled != isDesired else { return }
        let err = isEnabled ? disableHook() : enableHook()
        if err == noErr { isEnabled = isDesired }
    }

    /// Yield the lock when the app deactivates, keeping `scoped` intact so `apply()` reacquires
    /// it on reactivation if a focused surface still wants it.
    private func releaseWhileInactive() {
        guard isEnabled else { return }
        if disableHook() == noErr { isEnabled = false }
    }
}
