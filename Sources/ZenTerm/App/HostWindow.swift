import AppKit

final class HostWindow: NSWindow {
    static let minimumContentSize = NSSize(width: 480, height: 320)
    static let styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]

    var contentWidth: CGFloat { contentRect(forFrameRect: frame).width }

    private lazy var chromeFieldEditor = ChromeTextView.makeFieldEditor()

    // Measured from the window's top-left corner: the close button's leading edge and the buttons' vertical center.
    struct WindowButtonPlacement: Equatable {
        let leading: CGFloat
        let centerFromTop: CGFloat

        func shifted(by dx: CGFloat) -> WindowButtonPlacement {
            WindowButtonPlacement(leading: leading + dx, centerFromTop: centerFromTop)
        }
    }

    private struct WindowButtonLayout {
        let titlebarHeight: CGFloat
        let origins: [NSWindow.ButtonType: NSPoint]
    }

    private static let windowButtonTypes: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
    private var windowButtonPlacement: WindowButtonPlacement?
    private var windowButtonsVisible = true
    private var windowButtonMove = 0
    // Captured before the first placement, since AppKit exposes no default to return the buttons to.
    private var defaultWindowButtonLayout: WindowButtonLayout?

    var hoverCover: NSView? {
        didSet {
            guard hoverCover !== oldValue else { return }
            contentView?.hoverSuppressingDescendants().forEach { $0.hoverCoverDidChange() }
        }
    }

    /// Sets `contentMinSize` because a mounted overlay otherwise collapses the size AppKit derives from constraints.
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: Self.styleMask,
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
        setWindowButtonsHidden(!GeneralConfig.current.windowChrome)
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

    // AppKit lays the titlebar out again on a resize, a title change, a hide or an alpha change, putting the buttons back.
    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(frameRect, display: flag)
        if windowButtonPlacement != nil { layoutWindowButtons() }
    }

    override var title: String {
        didSet { if windowButtonPlacement != nil { layoutWindowButtons() } }
    }

    override func fieldEditor(_ createFlag: Bool, for object: Any?) -> NSText? {
        guard object is NSTextField else { return super.fieldEditor(createFlag, for: object) }
        return chromeFieldEditor
    }

    /// Moves the titlebar's buttons to `placement`, fading them in or out; hidden ones keep their spot for the next move.
    func moveWindowButtons(to placement: WindowButtonPlacement, visible: Bool, animated: Bool) {
        if defaultWindowButtonLayout == nil { defaultWindowButtonLayout = currentWindowButtonLayout() }
        let before = windowButtons.map { $0.convert($0.bounds, to: nil).origin }
        let wasShown = windowButtons.contains { !$0.isHidden && $0.alphaValue > 0 }
        windowButtonPlacement = placement
        windowButtonsVisible = visible
        windowButtonMove &+= 1
        let move = windowButtonMove
        let shown = visible && GeneralConfig.current.windowChrome
        let opacity: CGFloat = shown ? 1 : 0
        if shown { setWindowButtonsHidden(false) }
        guard animated, !Motion.isReduceMotionEnabled() else {
            windowButtons.forEach { $0.alphaValue = opacity }
            if !shown { setWindowButtonsHidden(true) }
            layoutWindowButtons()
            return
        }
        windowButtons.forEach { $0.alphaValue = opacity }
        layoutWindowButtons()
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.windowButtonMove == move else { return }
                if !shown { self.setWindowButtonsHidden(true) }
                self.layoutWindowButtons()
            }
        }
        for (button, start) in zip(windowButtons, before) {
            slide(button, from: start, fade: shown == wasShown ? nil : shown)
        }
        CATransaction.commit()
    }

    // A layer animation, since the buttons' own frame setter answers to AppKit's titlebar layout, not to an animator.
    // Coming in, the fade waits so it lands with the slide instead of showing the buttons before the card arrives.
    // Buttons already on screen, moving between the card and the docked column, only slide.
    private func slide(_ button: NSButton, from start: NSPoint, fade fadingIn: Bool?) {
        button.wantsLayer = true
        guard let layer = button.layer else { return }
        let end = button.convert(button.bounds, to: nil).origin
        let move = CABasicAnimation(keyPath: "transform.translation")
        move.fromValue = NSValue(size: NSSize(width: start.x - end.x, height: start.y - end.y))
        move.toValue = NSValue(size: .zero)
        move.duration = Motion.pageSlideDuration
        move.timingFunction = Motion.landingTiming
        layer.add(move, forKey: "windowButton.slide")
        guard let fadingIn else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = fadingIn ? 0 : 1
        fade.toValue = fadingIn ? 1 : 0
        fade.duration = Motion.fadeDuration
        fade.beginTime = CACurrentMediaTime() + (fadingIn ? Motion.pageSlideDuration - Motion.fadeDuration : 0)
        fade.fillMode = .backwards
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(fade, forKey: "windowButton.fade")
    }

    func reapplyWindowChrome() {
        guard let windowButtonPlacement else { return setWindowButtonsHidden(!GeneralConfig.current.windowChrome) }
        moveWindowButtons(to: windowButtonPlacement, visible: windowButtonsVisible, animated: false)
    }

    private var windowButtons: [NSButton] { Self.windowButtonTypes.compactMap { standardWindowButton($0) } }

    private func setWindowButtonsHidden(_ hidden: Bool) {
        windowButtons.forEach { $0.isHidden = hidden }
        if windowButtonPlacement != nil { layoutWindowButtons() }
    }

    private var titlebarContainer: NSView? { standardWindowButton(.closeButton)?.superview?.superview }

    private func currentWindowButtonLayout() -> WindowButtonLayout? {
        guard let titlebarContainer else { return nil }
        var origins: [NSWindow.ButtonType: NSPoint] = [:]
        for type in Self.windowButtonTypes { origins[type] = standardWindowButton(type)?.frame.origin }
        return WindowButtonLayout(titlebarHeight: titlebarContainer.frame.height, origins: origins)
    }

    // The titlebar only grows to hold the buttons, since it takes the clicks over everything it covers.
    // Mid-move it never shrinks, so a button travelling up out of a taller one is not clipped on the way.
    private func layoutWindowButtons(animated: Bool = false) {
        guard let layout = defaultWindowButtonLayout, let placement = windowButtonPlacement, let titlebarContainer,
            let closeOrigin = layout.origins[.closeButton],
            let buttonHeight = standardWindowButton(.closeButton)?.frame.height
        else { return }
        let height = max(
            layout.titlebarHeight, placement.centerFromTop + buttonHeight / 2,
            animated ? titlebarContainer.frame.height : 0)
        titlebarContainer.frame = NSRect(
            x: titlebarContainer.frame.minX, y: frame.height - height, width: titlebarContainer.frame.width,
            height: height)
        for type in Self.windowButtonTypes {
            guard let origin = layout.origins[type], let button = standardWindowButton(type) else { continue }
            (animated ? button.animator() : button).setFrameOrigin(
                NSPoint(
                    x: placement.leading + origin.x - closeOrigin.x,
                    y: height - placement.centerFromTop - buttonHeight / 2))
        }
    }
}
