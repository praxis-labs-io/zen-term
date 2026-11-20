import AppKit

class TabChip: ControlView, ThemeReapplying {
    static let height: CGFloat = ChromeMetrics.Height.sm
    static let chipFont = ChromeType.font(.caption, weight: .medium, face: .mono)
    // The rename editor matches it, or the text reflows on open.
    static let titleKern: CGFloat = 0.4
    static let labelInset: CGFloat = ChromeMetrics.Spacing.s8
    static let minWidth: CGFloat = 64
    static let maxChipWidth: CGFloat = 220

    private static let closeSlotSize: CGFloat = ChromeMetrics.Height.xs
    private static let closeSlotInset: CGFloat = ChromeMetrics.Spacing.s2
    private static let fadeRamp: CGFloat = ChromeMetrics.Spacing.s24

    private(set) var title = ""
    private(set) var isCurrent = false
    private(set) var isClosable = false
    private(set) var dotState: StateDot.State?
    private var firstClickTime: TimeInterval?
    private(set) var labelFrame = CGRect.zero

    let label = NSTextField(labelWithString: "")
    private let labelContainer = NSView()
    private let dot = StateDot()
    private let fadeMask = CAGradientLayer()
    let closeButton: IconButton

    var onCloseButton: (() -> Void)?

    var showsClose: Bool { isHovered && isClosable }

    var attributedLabelForTesting: NSAttributedString { label.attributedStringValue }
    var isCloseVisibleForTesting: Bool { !closeButton.isHidden }
    var isDotVisibleForTesting: Bool { !dot.isHidden }
    var closeButtonForTesting: IconButton { closeButton }
    var isHoveredForTesting: Bool { isHovered }
    var dotStateForTesting: StateDot.State? { dot.state }
    var dotColorForTesting: CGColor? { dot.colorForTesting }
    var dotFrameForTesting: CGRect { dot.frame }
    var closeFrameForTesting: CGRect { closeButton.frame }
    var closeSlotForTesting: CGRect { closeSlot }
    var labelFrameForTesting: CGRect { labelFrame }
    var isLabelFadedForTesting: Bool { labelContainer.layer?.mask != nil }
    var backgroundColorForTesting: NSColor? { layer?.backgroundColor.flatMap { NSColor(cgColor: $0) } }
    var isTitleTruncatedForTesting: Bool {
        label.cell?.expansionFrame(withFrame: label.bounds, in: label).isEmpty == false
    }

    init(closeLabel: String, closeShortcut: (() -> String?)? = nil) {
        closeButton = IconButton(
            symbol: "xmark",
            size: NSSize(width: Self.closeSlotSize, height: Self.closeSlotSize),
            pointSize: ChromeMetrics.Icon.xs, weight: .semibold,
            accessibilityLabel: closeLabel, shortcut: closeShortcut
        ) {}
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = ChromeMetrics.Radius.control

        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        labelContainer.wantsLayer = true
        labelContainer.addSubview(label)

        dot.isHidden = true

        closeButton.firesOnRelease = true
        closeButton.isHidden = true
        closeButton.onClick = { [weak self] in self?.onCloseButton?() }

        fadeMask.startPoint = CGPoint(x: 0, y: 0.5)
        fadeMask.endPoint = CGPoint(x: 1, y: 0.5)

        for view in [labelContainer, dot, closeButton] {
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.closeSlotInset),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func apply(title: String, isCurrent: Bool, isClosable: Bool, dot dotState: StateDot.State?) {
        self.title = title
        self.isCurrent = isCurrent
        self.isClosable = isClosable
        self.dotState = dotState
        restyle()
        needsLayout = true
    }

    var textWidth: CGFloat { ceil(label.cell?.cellSize.width ?? label.intrinsicContentSize.width) }

    var fittingWidth: CGFloat {
        let trailing = dotState == nil ? Self.labelInset : Self.closeSlotSize + Self.closeSlotInset
        return Self.clamp(Self.labelInset + textWidth + trailing)
    }

    static func clamp(_ width: CGFloat) -> CGFloat { min(max(width, minWidth), maxChipWidth) }

    func reapplyTheme() {
        restyle()
    }

    func restyle() {
        let chrome = Theme.current.chrome
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        paragraph.alignment = .center
        let styled = NSAttributedString(
            string: title,
            attributes: [
                .font: Self.chipFont, .kern: Self.titleKern, .paragraphStyle: paragraph,
                .foregroundColor: chrome.ink(isCurrent || isHovered ? .normal : .subtle),
            ])
        if label.attributedStringValue != styled {
            label.attributedStringValue = styled
            needsLayout = true
        }
        dot.state = dotState
        easeFill(isHovered && !isCurrent ? chrome.fill(.hover) : .clear)
        updateAccessories()
    }

    // The second press of a double-click lands on whichever chip slid under the pointer, so only the chip that took the first press owns the pair.
    func isSecondClickOfOwnPair(_ event: NSEvent) -> Bool {
        defer { firstClickTime = event.clickCount == 1 ? event.timestamp : nil }
        guard event.clickCount == 2, let firstClickTime else { return false }
        return event.timestamp - firstClickTime <= NSEvent.doubleClickInterval
    }

    override func hoverDidChange() {
        restyle()
        needsLayout = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        let passive: [NSView] = [labelContainer, dot]
        return passive.contains { hit === $0 || hit.isDescendant(of: $0) } ? self : hit
    }

    override func layout() {
        super.layout()
        let slot = closeSlot
        dot.frame = CGRect(
            x: slot.midX - StateDot.diameter / 2, y: slot.midY - StateDot.diameter / 2,
            width: StateDot.diameter, height: StateDot.diameter)
        let trailing = dotState == nil ? bounds.width - Self.labelInset : slot.minX
        labelFrame = CGRect(
            x: Self.labelInset, y: 0, width: max(0, trailing - Self.labelInset), height: bounds.height)
        labelContainer.frame = labelFrame
        let labelHeight = label.intrinsicContentSize.height
        label.frame = CGRect(
            x: 0, y: (bounds.height - labelHeight) / 2, width: labelFrame.width, height: labelHeight)
        updateAccessories()
    }

    private var closeSlot: CGRect {
        CGRect(
            x: bounds.width - Self.closeSlotInset - Self.closeSlotSize,
            y: (bounds.height - Self.closeSlotSize) / 2,
            width: Self.closeSlotSize, height: Self.closeSlotSize)
    }

    private func updateAccessories() {
        let closing = showsClose
        closeButton.isHidden = !closing
        dot.isHidden = dotState == nil || closing
        guard closing, labelFrame.width > 0 else {
            labelContainer.layer?.mask = nil
            return
        }
        let width = labelFrame.width
        let clearAt = min(max(closeSlot.minX - labelFrame.minX, 0), width)
        let opaqueAt = min(max(clearAt - Self.fadeRamp, width / 2), clearAt)
        let opaque = Theme.current.chrome.foreground.nsColor.withAlphaComponent(1).cgColor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fadeMask.frame = labelContainer.bounds
        fadeMask.colors = [opaque, opaque, NSColor.clear.cgColor, NSColor.clear.cgColor]
        fadeMask.locations = [0, opaqueAt / width, clearAt / width, 1].map { NSNumber(value: Double($0)) }
        labelContainer.layer?.mask = fadeMask
        CATransaction.commit()
    }
}
