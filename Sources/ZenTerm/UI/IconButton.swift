import AppKit

// `NSImageView` takes alignment insets from SF Symbol baseline metadata, which hangs symbols off-centre beside brand marks.
private final class GlyphView: NSImageView {
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsets() }
}

final class IconButton: ControlView, ThemeReapplying {
    var onClick: () -> Void
    private let icon = GlyphView()

    var firesOnRelease = false
    private var isPressed = false

    var isKeyboardFocusable = false
    var onArrowUp: (() -> Void)?
    var onArrowDown: (() -> Void)?
    var onArrowLeft: (() -> Void)?
    var onArrowRight: (() -> Void)?
    var onTab: (() -> Void)?
    var onBacktab: (() -> Void)?

    var isActive = false { didSet { update() } }

    var showsActivity = false { didSet { activityDot.state = showsActivity ? .live : nil } }

    var activityDotHiddenForTesting: Bool { activityDot.state == nil }
    var activityDotForTesting: StateDot { activityDot }
    private let activityDot = StateDot()
    private static let dotInset: CGFloat = StateDot.diameter / 2 + 2

    private let tooltip: TooltipHost

    private let restsFilled: Bool

    init(
        symbol: String, size: NSSize = NSSize(width: ChromeMetrics.Height.sm, height: ChromeMetrics.Height.sm),
        pointSize: CGFloat = ChromeMetrics.Icon.sm, weight: NSFont.Weight = .medium,
        accessibilityLabel label: String, shortcut: (() -> String?)? = nil,
        restsFilled: Bool = false,
        onClick: @escaping () -> Void
    ) {
        self.onClick = onClick
        self.restsFilled = restsFilled
        tooltip = TooltipHost(label: label, shortcut: shortcut)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = ChromeMetrics.Radius.control
        icon.image = IconCatalog.image(symbol, pointSize: pointSize, weight: weight)
        icon.imageScaling = .scaleNone
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)
        translatesAutoresizingMaskIntoConstraints = false

        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(label)

        activityDot.translatesAutoresizingMaskIntoConstraints = false
        addSubview(activityDot)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: size.width),
            heightAnchor.constraint(equalToConstant: size.height),
            icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: size.width),
            icon.heightAnchor.constraint(equalToConstant: size.height),
            activityDot.centerXAnchor.constraint(equalTo: trailingAnchor, constant: -Self.dotInset),
            activityDot.centerYAnchor.constraint(equalTo: topAnchor, constant: Self.dotInset),
        ])
        update()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hoverDidChange() {
        if !isHovered { tooltip.hide(from: self) }
        update()
    }

    override func focusDidChange() { update() }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        tooltip.show(from: self)
    }

    override func mouseDown(with event: NSEvent) {
        tooltip.hide(from: self)
        guard firesOnRelease else { return onClick() }
        isPressed = event.clickCount == 1
    }
    override func mouseUp(with event: NSEvent) {
        guard firesOnRelease, isPressed else { return super.mouseUp(with: event) }
        isPressed = false
        guard !isHiddenOrHasHiddenAncestor, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick()
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func accessibilityPerformPress() -> Bool { onClick(); return true }

    override var acceptsFirstResponder: Bool { isKeyboardFocusable }

    // The focus ring is drawn on a layer border instead.
    override func drawFocusRingMask() {}

    override func keyDown(with event: NSEvent) {
        guard isKeyboardFocusable else { return super.keyDown(with: event) }
        switch KeyboardFocus.key(for: event) {
        case .activate where KeyboardFocus.isUnmodified(event): onClick()
        case .up where onArrowUp != nil: onArrowUp?()
        case .down where onArrowDown != nil: onArrowDown?()
        case .left where onArrowLeft != nil: onArrowLeft?()
        case .right where onArrowRight != nil: onArrowRight?()
        case .tab(shift: false) where onTab != nil: onTab?()
        case .tab(shift: true) where onBacktab != nil: onBacktab?()
        default: super.keyDown(with: event)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { tooltip.hide(from: self) }
    }

    var isHoveredForTesting: Bool { isHovered }
    var iconTintForTesting: NSColor? { icon.contentTintColor }

    var tooltipLabelForTesting: String { tooltip.label }
    var tooltipShortcutForTesting: String? { tooltip.shortcutForTesting }

    func reapplyTheme() { update() }

    #if DEBUG
        func forceHoverForGallery() { setHovered(true) }
    #endif

    private func update() {
        let chrome = Theme.current.chrome
        let bg: NSColor
        let tint: NSColor
        if isActive {
            bg = chrome.fill(.active); tint = chrome.ink(.normal)
        } else if isHovered {
            bg = chrome.fill(.hover); tint = chrome.ink(.normal)
        } else {
            bg = restsFilled ? chrome.fill(.rest) : .clear
            tint = chrome.ink(.subtle)
        }
        easeFill(bg)
        showFocusRing(hasKeyboardFocus)
        icon.contentTintColor = tint
    }
}
