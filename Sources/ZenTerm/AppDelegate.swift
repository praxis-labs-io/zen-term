import AppKit
import TerminalKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: HostWindow!
    private let surface = TerminalSurfaceFactory.make()
    private let logger = ConsoleSurfaceLogger()
    private let keys = KeyInterceptor()

    func applicationDidFinishLaunching(_ notification: Notification) {
        surface.delegate = logger

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
