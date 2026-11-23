import AppKit

// A closed drawer in a tab drawing, drawn as a dashed rail that opens into a command field.
final class DrawerRail: ControlView, ThemeReapplying {
    let region: Workspace.Region
    var onOpen: (() -> Void)?
    var onEdge: ((RegionCommandField.Edge) -> Void)?
    var onTab: (() -> Void)?
    var onBacktab: (() -> Void)?

    private let border = CAShapeLayer()
    private let glyph = NSImageView()
    private let tooltip: TooltipHost

    var tooltipLabelForTesting: String { tooltip.label }
    var borderStrokeForTesting: CGColor? { border.strokeColor }

    init(region: Workspace.Region) {
        self.region = region
        let name = WorkspaceForm.label(for: region).lowercased()
        tooltip = TooltipHost(label: "Add a \(name) command")
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = ChromeMetrics.Radius.control
        border.fillColor = nil
        border.lineDashPattern = [4, 3]
        layer?.addSublayer(border)
        glyph.image = IconCatalog.image("plus", pointSize: ChromeMetrics.Icon.sm)
        glyph.imageScaling = .scaleNone
        glyph.translatesAutoresizingMaskIntoConstraints = true
        addSubview(glyph)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(tooltip.label)
        restyle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        glyph.frame = bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        border.frame = bounds
        border.path = CGPath(
            roundedRect: bounds.insetBy(dx: ChromeMetrics.Border.width / 2, dy: ChromeMetrics.Border.width / 2),
            cornerWidth: ChromeMetrics.Radius.control, cornerHeight: ChromeMetrics.Radius.control, transform: nil)
        CATransaction.commit()
    }

    func reapplyTheme() { restyle() }

    private func restyle() {
        let chrome = Theme.current.chrome
        border.strokeColor = (hasKeyboardFocus ? chrome.focusRing : chrome.ink(.faint)).cgColor
        border.lineWidth = ChromeMetrics.Border.width
        easeFill(showsHover ? chrome.fill(.hover) : .clear)
        glyph.contentTintColor = chrome.ink(showsHover || hasKeyboardFocus ? .normal : .muted)
    }

    override var acceptsFirstResponder: Bool { true }

    override func focusDidChange() { restyle() }

    override func drawFocusRingMask() {}

    override func keyDown(with event: NSEvent) {
        switch KeyboardFocus.key(for: event) {
        case .left: onEdge?(.left)
        case .right: onEdge?(.right)
        case .up: onEdge?(.up)
        case .down: onEdge?(.down)
        case .tab(let shift): (shift ? onBacktab : onTab)?()
        case .activate where KeyboardFocus.isUnmodified(event): onOpen?()
        default: super.keyDown(with: event)
        }
    }

    override func hoverDidChange() {
        if !showsHover { tooltip.hide(from: self) }
        restyle()
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        guard !isHoverSuppressed else { return }
        tooltip.show(from: self)
    }

    override func mouseDown(with event: NSEvent) {
        tooltip.hide(from: self)
        onOpen?()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { tooltip.hide(from: self) }
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func accessibilityPerformPress() -> Bool {
        onOpen?()
        return true
    }
}
