import AppKit

final class HostWindow: NSWindow {
    /// Sets `contentMinSize` because a mounted overlay otherwise collapses the size AppKit derives from constraints.
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        contentMinSize = NSSize(width: 480, height: 320)
        tabbingMode = .disallowed
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        setWindowChromeVisible(GeneralConfig.current.windowChrome)
    }

    func setWindowChromeVisible(_ shown: Bool) {
        standardWindowButton(.closeButton)?.isHidden = !shown
        standardWindowButton(.miniaturizeButton)?.isHidden = !shown
        standardWindowButton(.zoomButton)?.isHidden = !shown
    }
}
