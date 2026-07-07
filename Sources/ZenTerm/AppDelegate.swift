import AppKit

/// Owns every window and routes chords/Copy/Paste to whichever is key. `⌘n` opens a
/// new window (inheriting the key window's focused-pane cwd); every other chord goes
/// to the key window's `WindowController`. Native macOS tabbing is disallowed on
/// `HostWindow`, so each window is an ordinary independently-tileable window.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windows: [WindowController] = []
    private let keys = KeyInterceptor()

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainMenu.install(copyPaste: nil)  // Copy/Paste route via the responder chain
        newWindow(initialCWD: nil, centered: true)

        keys.onReservedChord = { [weak self] chord in self?.route(chord) }
        keys.start()
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Route a chord: `⌘n` makes a new window; everything else goes to the key
    /// window's controller.
    private func route(_ chord: KeyInterceptor.ReservedChord) {
        if case .newWindow = chord {
            // ⌘N is intercepted here before `handle(_:)`, so a palette's modal gate
            // doesn't cover it — swallow it explicitly while either palette is open.
            if keyController()?.isModalPaletteOpen == true { return }
            newWindow(initialCWD: keyController()?.focusedCWD, centered: false)
            return
        }
        keyController()?.handle(chord)
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
        if isPaletteModal {
            NSApp.keyWindow?.firstResponder?.tryToPerform(#selector(NSText.copy(_:)), with: sender); return
        }
        keyController()?.copyFromSurface(sender)
    }
    @objc func pasteToSurface(_ sender: Any?) {
        if isPaletteModal {
            NSApp.keyWindow?.firstResponder?.tryToPerform(#selector(NSText.paste(_:)), with: sender); return
        }
        keyController()?.pasteToSurface(sender)
    }

    /// While either palette is modal, Copy/Paste must act on its search field, not the
    /// terminal hidden behind it (else ⌘V would inject the clipboard into that shell).
    private var isPaletteModal: Bool { keyController()?.isModalPaletteOpen == true }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
