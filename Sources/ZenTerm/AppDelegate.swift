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

        // Assign before start() so a first shell that dies instantly still closes the window.
        canvas.onLastPaneClosed = { [weak self] in self?.window.close() }
        canvas.start()

        keys.onReservedChord = { [weak self] chord in
            self?.handle(chord)
        }
        keys.start()
    }

    private func handle(_ chord: KeyInterceptor.ReservedChord) {
        switch chord {
        case .splitVertical:   canvas.split(.vertical)
        case .splitHorizontal: canvas.split(.horizontal)
        case .navLeft:  canvas.navigate(.left)
        case .navRight: canvas.navigate(.right)
        case .navUp:    canvas.navigate(.up)
        case .navDown:  canvas.navigate(.down)
        case .closePane:
            if canvas.closeFocused() == false { window.close() }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
