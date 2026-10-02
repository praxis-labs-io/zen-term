import AppKit

// A closed drawer in a tab drawing, drawn as a dashed rail that opens into a command field.
final class DrawerRail: NSView {
    let region: Workspace.Region
    var onOpen: (() -> Void)?
    var onEdge: ((RegionCommandField.Edge) -> Void)?
    var onTab: (() -> Void)?
    var onBacktab: (() -> Void)?

    private let border = CAShapeLayer()
    private let glyph = NSImageView()
    private let tooltip: TooltipHost
    private var isHovered = false
    private var hasFocus = false

    var tooltipLabelForTesting: String { tooltip.label }

    init(region: Workspace.Region) {
        self.region = region
        let name = WorkspaceForm.label(for: region).lowercased()
        tooltip = TooltipHost(label: "Add a \(name) command")
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 7
        border.fillColor = nil
        border.lineDashPattern = [4, 3]
        layer?.addSublayer(border)
        glyph.image = IconCatalog.image("plus", pointSize: 12)
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
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 7, cornerHeight: 7, transform: nil)
        CATransaction.commit()
    }

    func reapplyTheme() { restyle() }

    private func restyle() {
        let chrome = Theme.current.chrome
        border.strokeColor = (hasFocus ? chrome.accent.nsColor : chrome.ink(.faint)).cgColor
        border.lineWidth = hasFocus ? 1.5 : 1
        layer?.backgroundColor = (isHovered ? chrome.fill(.hover) : .clear).cgColor
        glyph.contentTintColor = chrome.ink(isHovered || hasFocus ? .normal : .muted)
    }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok {
            hasFocus = true
            restyle()
        }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        hasFocus = false
        restyle()
        return super.resignFirstResponder()
    }

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

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(
            NSTrackingArea(
                rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        restyle()
        tooltip.show(from: self)
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        restyle()
        tooltip.hide(from: self)
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
