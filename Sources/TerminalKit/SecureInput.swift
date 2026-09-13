import AppKit
import Carbon.HIToolbox

// Process-global secure keyboard entry, held only while a focused surface wants it and the app is active.
final class SecureInput {
    static let shared = SecureInput()

    // Valued by focus, so a background pane at a password prompt never holds the lock.
    private var scoped: [ObjectIdentifier: Bool] = [:]

    private var isEnabled = false

    private var observers: [NSObjectProtocol] = []

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

    func setScoped(_ id: ObjectIdentifier, focused: Bool) {
        scoped[id] = focused
        apply()
    }

    func removeScoped(_ id: ObjectIdentifier) {
        scoped[id] = nil
        apply()
    }

    private func apply() {
        guard isActiveHook() else { return }
        guard isEnabled != isDesired else { return }
        let err = isEnabled ? disableHook() : enableHook()
        if err == noErr { isEnabled = isDesired }
    }

    private func releaseWhileInactive() {
        guard isEnabled else { return }
        if disableHook() == noErr { isEnabled = false }
    }
}
