import AppKit
import TerminalKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: HostWindow!
    private let surface = TerminalSurfaceFactory.make()
    private let logger = ConsoleSurfaceLogger()

    func applicationDidFinishLaunching(_ notification: Notification) {
        surface.delegate = logger

        window = HostWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 560))
        let content = window.contentView!

        // Task 5: place the terminal edge-to-edge. Task 6 wraps it in PaneHostView.
        let terminalView = surface.view
        terminalView.frame = content.bounds
        terminalView.autoresizingMask = [.width, .height]
        content.addSubview(terminalView)

        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        surface.start(TerminalSurfaceConfig())
        surface.focus()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
