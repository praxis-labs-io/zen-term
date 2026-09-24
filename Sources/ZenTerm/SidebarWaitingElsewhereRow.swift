import AppKit

final class SidebarWaitingElsewhereRow: NSView, HoverSuppressing {
    var onArrowUp: (() -> Void)?
    var onArrowDown: (() -> Void)?
    var onEscape: (() -> Void)?
    var onFocusChanged: (() -> Void)?

    private let label = NSTextField(labelWithString: "")
    private let dot = NSView()
    private let onActivate: () -> Void
    private let tooltip = TooltipHost(label: "Jump to the agent waiting longest")
    private var isTakingKeyboardFocus = false
    private var trackingArea: NSTrackingArea?
    private var isFocusedStop = false
    private var isHovered = false
    private var isHoverSuppressed = false

    static let height: CGFloat = 30
    private static let inset: CGFloat = 10
    private static let gap: CGFloat = 8
    private static let dotDiameter: CGFloat = 7

    static func text(agents: Int, windows: Int) -> String {
        "\(agents) waiting in \(windows > 1 ? "other windows" : "another window")"
    }

    init(onActivate: @escaping () -> Void) {
        self.onActivate = onActivate
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 6
        setAccessibilityElement(true)
        setAccessibilityRole(.button)

        label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        dot.wantsLayer = true
        dot.layer?.cornerRadius = Self.dotDiameter / 2
        dot.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dot)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.inset),
            label.trailingAnchor.constraint(lessThanOrEqualTo: dot.leadingAnchor, constant: -Self.gap),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.inset),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: Self.dotDiameter),
            dot.heightAnchor.constraint(equalToConstant: Self.dotDiameter),
        ])
        reapplyTheme()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func render(agents: Int, windows: Int) {
        let text = Self.text(agents: agents, windows: windows)
        guard text != label.stringValue else { return }
        label.stringValue = text
        setAccessibilityLabel(text)
    }

    var textForTesting: String { label.stringValue }

    var fillForTesting: CGColor? { layer?.backgroundColor }

    func reapplyTheme() {
        label.textColor = Theme.current.chrome.ink(.muted)
        dot.layer?.backgroundColor = AttentionTone.waiting.ink.cgColor
        refreshFill()
    }

    private func refreshFill() {
        let chrome = Theme.current.chrome
        if isFocusedStop {
            layer?.backgroundColor = chrome.selectionFill.cgColor
        } else if isHovered, !isHoverSuppressed {
            layer?.backgroundColor = chrome.fill(.hover).cgColor
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
        }
    }

    // AppKit promotes any clicked view that accepts, so a row accepts only in `takeKeyboardFocus`.
    override var acceptsFirstResponder: Bool { isTakingKeyboardFocus }

    func takeKeyboardFocus() {
        isTakingKeyboardFocus = true
        window?.makeFirstResponder(self)
        isTakingKeyboardFocus = false
    }

    override func becomeFirstResponder() -> Bool {
        isFocusedStop = true
        refreshFill()
        onFocusChanged?()
        return true
    }

    override func resignFirstResponder() -> Bool {
        isFocusedStop = false
        refreshFill()
        onFocusChanged?()
        return true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        refreshFill()
        guard !isHoverSuppressed else { return }
        tooltip.show(from: self)
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        refreshFill()
        tooltip.hide(from: self)
    }

    func refreshHover() {
        let inside = pointerIsInside
        guard inside != isHovered else { return }
        isHovered = inside
        if !inside { tooltip.hide(from: self) }
        refreshFill()
    }

    func setHoverSuppressed(_ suppressed: Bool) {
        guard suppressed != isHoverSuppressed else { return }
        isHoverSuppressed = suppressed
        if suppressed { tooltip.hide(from: self) } else { isHovered = pointerIsInside }
        refreshFill()
    }

    override func viewDidHide() {
        super.viewDidHide()
        isHovered = false
        refreshFill()
        tooltip.hide(from: self)
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
