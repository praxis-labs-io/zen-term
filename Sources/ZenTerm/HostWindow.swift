import AppKit

final class HostWindow: NSWindow {
    static let minimumContentSize = NSSize(width: 480, height: 320)

    var contentWidth: CGFloat { contentRect(forFrameRect: frame).width }

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
        contentMinSize = Self.minimumContentSize
        tabbingMode = .disallowed
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        setWindowChromeVisible(GeneralConfig.current.windowChrome)
    }

    // A frame saved by an older build, or on a wider screen, can sit under the minimum or off the display.
    func setFrameWithinLimits(_ frame: NSRect, animate: Bool) {
        var target = frame
        let floor = frameRect(forContentRect: NSRect(origin: .zero, size: contentMinSize)).size
        target.size.width = max(target.width, floor.width)
        target.size.height = max(target.height, floor.height)
        if let visible = (screen ?? NSScreen.main)?.visibleFrame {
            target.size.width = min(target.width, visible.width)
            target.size.height = min(target.height, visible.height)
            target.origin.x = min(max(target.minX, visible.minX), visible.maxX - target.width)
            target.origin.y = min(max(target.minY, visible.minY), visible.maxY - target.height)
        }
        setFrame(target, display: true, animate: animate)
    }

    func setWindowChromeVisible(_ shown: Bool) {
        standardWindowButton(.closeButton)?.isHidden = !shown
        standardWindowButton(.miniaturizeButton)?.isHidden = !shown
        standardWindowButton(.zoomButton)?.isHidden = !shown
    }
}
