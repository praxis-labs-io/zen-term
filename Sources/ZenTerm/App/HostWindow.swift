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
    static let slideKey = "windowButton.slide"
    static let fadeKey = "windowButton.fade"
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
        for name in [NSWindow.didResizeNotification, NSWindow.didExitFullScreenNotification, NSWindow.didDeminiaturizeNotification] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(titlebarWasLaidOut), name: name, object: self)
        }
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

    // AppKit lays the titlebar out again on these, and on a hide or an alpha change, putting the buttons back.
    @objc private func titlebarWasLaidOut() {
        if windowButtonPlacement != nil { layoutWindowButtons() }
    }

    override var title: String {
        didSet { titlebarWasLaidOut() }
    }

    override func fieldEditor(_ createFlag: Bool, for object: Any?) -> NSText? {
        guard object is NSTextField else { return super.fieldEditor(createFlag, for: object) }
        return chromeFieldEditor
    }

    func moveWindowButtons(to placement: WindowButtonPlacement, visible: Bool, animated: Bool) {
        if defaultWindowButtonLayout == nil { defaultWindowButtonLayout = currentWindowButtonLayout() }
        let before = windowButtons.map(onScreenOrigin)
        for button in windowButtons {
            for key in [Self.slideKey, Self.fadeKey] { button.layer?.removeAnimation(forKey: key) }
        }
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
        layoutWindowButtons(keepingTitlebarHeight: true)
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

    // A layer animation: the buttons' own frame setter answers to AppKit's titlebar layout, not to an animator.
    private func slide(_ button: NSButton, from start: NSPoint, fade fadingIn: Bool?) {
        button.wantsLayer = true
        guard let layer = button.layer else { return }
        let end = button.convert(button.bounds, to: nil).origin
        let move = CABasicAnimation(keyPath: "transform.translation")
        move.fromValue = NSValue(size: NSSize(width: start.x - end.x, height: start.y - end.y))
        move.toValue = NSValue(size: .zero)
        move.duration = Motion.pageSlideDuration
        move.timingFunction = Motion.landingTiming
        layer.add(move, forKey: Self.slideKey)
        guard let fadingIn else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = fadingIn ? 0 : 1
        fade.toValue = fadingIn ? 1 : 0
        fade.duration = Motion.fadeDuration
        fade.beginTime = CACurrentMediaTime() + (fadingIn ? fadeInDelay : 0)
        fade.fillMode = .backwards
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(fade, forKey: Self.fadeKey)
    }

    // Coming in, the fade lands with the slide, so the buttons never show before the card arrives.
    private var fadeInDelay: CFTimeInterval { Motion.pageSlideDuration - Motion.fadeDuration }

    private func onScreenOrigin(_ button: NSButton) -> NSPoint {
        let origin = button.convert(button.bounds, to: nil).origin
        let inFlight = (button.layer?.presentation()?.value(forKeyPath: "transform.translation") as? NSValue)?.sizeValue
        return NSPoint(x: origin.x + (inFlight?.width ?? 0), y: origin.y + (inFlight?.height ?? 0))
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

    // Mid-slide the titlebar keeps its height, so a button leaving a taller one is not clipped on the way out.
    private func layoutWindowButtons(keepingTitlebarHeight: Bool = false) {
        guard let layout = defaultWindowButtonLayout, let placement = windowButtonPlacement, let titlebarContainer,
            let closeOrigin = layout.origins[.closeButton],
            let buttonHeight = standardWindowButton(.closeButton)?.frame.height
        else { return }
        let height = max(
            layout.titlebarHeight, placement.centerFromTop + buttonHeight / 2,
            keepingTitlebarHeight ? titlebarContainer.frame.height : 0)
        titlebarContainer.frame = NSRect(
            x: titlebarContainer.frame.minX, y: frame.height - height, width: titlebarContainer.frame.width,
            height: height)
        for type in Self.windowButtonTypes {
            guard let origin = layout.origins[type], let button = standardWindowButton(type) else { continue }
            button.setFrameOrigin(
                NSPoint(
                    x: placement.leading + origin.x - closeOrigin.x,
                    y: height - placement.centerFromTop - buttonHeight / 2))
        }
    }
}
