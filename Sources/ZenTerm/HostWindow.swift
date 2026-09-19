import AppKit

final class HostWindow: NSWindow {
    private static let minimumContentSize = NSSize(width: 480, height: 320)

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

    func reserveContentWidth(_ width: CGFloat) {
        contentMinSize = NSSize(
            width: Self.minimumContentSize.width + width, height: Self.minimumContentSize.height)
        let content = contentRect(forFrameRect: frame)
        guard content.width < contentMinSize.width else { return }
        var target = frame
        target.size.width += contentMinSize.width - content.width
        if let visible = screen?.visibleFrame {
            target.size.width = min(target.width, visible.width)
            if target.maxX > visible.maxX { target.origin.x = max(visible.minX, visible.maxX - target.width) }
        }
        setFrame(target, display: true)
    }

    /// Restores a saved frame that the minimum may have outgrown since, clamped to it and kept on screen.
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
