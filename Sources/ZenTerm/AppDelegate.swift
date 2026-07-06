import AppKit
import TerminalKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    // Set in applicationDidFinishLaunching before any code path can read it; a
    // documented AppKit force-unwrap, like contentView!.
    private var window: HostWindow!
    private let canvas = PaneCanvasController()
    private let keys = KeyInterceptor()

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = HostWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 560))
        let content = window.contentView!

        canvas.canvasView.frame = content.bounds
        canvas.canvasView.autoresizingMask = [.width, .height]
        content.addSubview(canvas.canvasView)

        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        canvas.start()

        keys.onReservedChord = { [weak self] chord in
            self?.handle(chord)
        }
        keys.start()
    }

    private func handle(_ chord: KeyInterceptor.ReservedChord) {
        // Split/close/nav wired in Task 11.
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
