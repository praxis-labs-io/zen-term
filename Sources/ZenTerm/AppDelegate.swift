import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: WindowController!
    private let keys = KeyInterceptor()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let wc = WindowController(contentRect: NSRect(x: 0, y: 0, width: 900, height: 560),
                                  initialCWD: nil)
        wc.window.center()
        wc.onLastTabClosed = { [weak wc] in wc?.window.close() }
        controller = wc

        MainMenu.install(copyPaste: controller)
        wc.showAndStart()
        NSApp.activate(ignoringOtherApps: true)

        keys.onReservedChord = { [weak self] chord in self?.controller.handle(chord) }
        keys.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
