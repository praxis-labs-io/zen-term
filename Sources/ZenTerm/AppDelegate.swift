import AppKit
import TerminalKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: HostWindow!
    private let surface = TerminalSurfaceFactory.make()
    private let keys = KeyInterceptor()

    func applicationDidFinishLaunching(_ notification: Notification) {
        surface.delegate = self

        window = HostWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 560))
        let content = window.contentView!

        let pane = PaneHostView(content: surface.view)
        pane.frame = content.bounds
        pane.autoresizingMask = [.width, .height]
        content.addSubview(pane)

        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        surface.start(TerminalSurfaceConfig())
        surface.focus()

        keys.onReservedChord = { [weak self] chord in
            switch chord {
            case .logProbe:
                print("[reserved] ⌘K intercepted by chrome — did NOT reach the PTY")
            case .close:
                print("[reserved] ⌘W intercepted by chrome")
                self?.surface.terminate()
                self?.window.close()
            }
        }
        keys.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

/// Chrome-side handling of surface events: Epic 0 logs the observable ones to the
/// console, and closes the window when the shell exits — which quits the app via
/// `applicationShouldTerminateAfterLastWindowClosed`.
extension AppDelegate: TerminalSurfaceDelegate {
    func surface(_ s: TerminalSurface, titleDidChange title: String) {
        print("[title] \(title)")
    }
    func surface(_ s: TerminalSurface, cwdDidChange url: URL) {
        print("[cwd] \(url.path)")
    }
    func surfaceDidRingBell(_ s: TerminalSurface) {
        print("[bell]")
    }
    func surfaceDidExit(_ s: TerminalSurface, code: Int32?) {
        print("[exit] code=\(code.map(String.init) ?? "nil")")
        window.close()
    }
}
