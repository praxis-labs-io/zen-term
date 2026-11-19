import AppKit

class SidebarJumpRow: ControlView, HoverSuppressing, ThemeReapplying {
    var onArrowUp: (() -> Void)?
    var onArrowDown: (() -> Void)?
    var onEscape: (() -> Void)?
    var onFocusChanged: (() -> Void)?

    let tooltip: TooltipHost
    private let onActivate: () -> Void
    private var isTakingKeyboardFocus = false
    private var isHoverSuppressed = false

    init(tooltip: String, onActivate: @escaping () -> Void) {
        self.tooltip = TooltipHost(label: tooltip)
        self.onActivate = onActivate
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = ChromeMetrics.Radius.control
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var fillForTesting: CGColor? { layer?.backgroundColor }
    var ringForTesting: CGColor? { layer?.borderColor }

    func reapplyTheme() {
        refreshFill()
    }

    private func refreshFill() {
        showFocusRing(hasKeyboardFocus)
        easeFill(isHovered && !isHoverSuppressed ? Theme.current.chrome.fill(.hover) : .clear)
    }

    // AppKit promotes any clicked view that accepts, so a row accepts only in `takeKeyboardFocus`.
    override var acceptsFirstResponder: Bool { isTakingKeyboardFocus }

    func takeKeyboardFocus() {
        isTakingKeyboardFocus = true
        window?.makeFirstResponder(self)
        isTakingKeyboardFocus = false
    }

    override func focusDidChange() {
        refreshFill()
        onFocusChanged?()
    }

    override func hoverDidChange() {
        if !isHovered { tooltip.hide(from: self) }
        refreshFill()
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        guard !isHoverSuppressed else { return }
        tooltip.show(from: self)
    }

    func setHoverSuppressed(_ suppressed: Bool) {
        guard suppressed != isHoverSuppressed else { return }
        isHoverSuppressed = suppressed
        if suppressed { tooltip.hide(from: self) } else { refreshHover() }
        refreshFill()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { tooltip.hide(from: self) }
    }

    override func accessibilityPerformPress() -> Bool { onActivate(); return true }

    override func mouseDown(with event: NSEvent) {
        tooltip.hide(from: self)
        onActivate()
    }

    override func keyDown(with event: NSEvent) {
        switch KeyboardFocus.key(for: event) {
        case .up: onArrowUp?()
        case .down: onArrowDown?()
        case .activate where KeyboardFocus.isReturn(event): onActivate()
        case .escape where onEscape != nil && KeyboardFocus.isUnmodified(event): onEscape?()
        default: super.keyDown(with: event)
        }
    }
}
