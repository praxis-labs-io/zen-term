import AppKit

class TabChip: ControlView, ThemeReapplying {
    enum Indicator: Equatable {
        case dot(StateDot.State)
        case spinner
    }

    static let height: CGFloat = ChromeMetrics.Height.sm
    static let chipFont = ChromeType.font(.caption, weight: .medium, face: .mono)
    // The rename editor matches it, or the text reflows on open.
    static let titleKern: CGFloat = 0.4
    static let labelInset: CGFloat = ChromeMetrics.Spacing.s8
    static let minWidth: CGFloat = 64
    static let maxChipWidth: CGFloat = 220

    private static let processInset: CGFloat = ChromeMetrics.Spacing.s4
    private static let processGap: CGFloat = ChromeMetrics.Spacing.s4
    private static let processSize = IconBadge.Size.small
    private static let closeSlotSize: CGFloat = ChromeMetrics.Height.xs
    private static let closeSlotInset: CGFloat = ChromeMetrics.Spacing.s2
    private static let fadeRamp: CGFloat = ChromeMetrics.Spacing.s24
    private static let indicatorSlotGrowth: CGFloat = closeSlotInset + closeSlotSize - labelInset

    private(set) var title = ""
    private(set) var isCurrent = false
    private(set) var isClosable = false
    private(set) var indicator: Indicator?
    private(set) var process: ProcessIcon?
    private var firstClickTime: TimeInterval?
    private(set) var labelFrame = CGRect.zero

    let label = NSTextField(labelWithString: "")
    private let labelContainer = NSView()
    private let dot = StateDot()
    private let spinner = Spinner()
    private let processBadge = IconBadge(process: .shell, size: TabChip.processSize)
    private let fadeMask = CAGradientLayer()
    let closeButton: IconButton

    var onCloseButton: (() -> Void)?

    var showsClose: Bool { showsHover && isClosable }

    var attributedLabelForTesting: NSAttributedString { label.attributedStringValue }
    var isCloseVisibleForTesting: Bool { !closeButton.isHidden }
    var isDotVisibleForTesting: Bool { !dot.isHidden }
    var processBadgeForTesting: IconBadge? { processBadge.isHidden ? nil : processBadge }
    var closeButtonForTesting: IconButton { closeButton }
    var isHoveredForTesting: Bool { isHovered }
    var dotStateForTesting: StateDot.State? { dot.state }
    var dotColorForTesting: CGColor? { dot.colorForTesting }
    var dotFrameForTesting: CGRect { dot.frame }
    var isSpinningForTesting: Bool { !spinner.isHidden && spinner.isSpinning }
    var spinnerFrameForTesting: CGRect { spinner.frame }
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
        spinner.translatesAutoresizingMaskIntoConstraints = true
        spinner.role = \.working
        spinner.isHidden = true

        processBadge.translatesAutoresizingMaskIntoConstraints = true
        processBadge.isHidden = true

        closeButton.firesOnRelease = true
        closeButton.isHidden = true
        closeButton.onClick = { [weak self] in self?.onCloseButton?() }

        fadeMask.startPoint = CGPoint(x: 0, y: 0.5)
        fadeMask.endPoint = CGPoint(x: 1, y: 0.5)

        for view in [processBadge, labelContainer, dot, spinner, closeButton] {
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.closeSlotInset),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func apply(title: String, isCurrent: Bool, isClosable: Bool, indicator: Indicator?, process: ProcessIcon? = nil) {
        self.title = title
        self.isCurrent = isCurrent
        self.isClosable = isClosable
        self.indicator = indicator
        self.process = process
        restyle()
        needsLayout = true
    }

    var textWidth: CGFloat { ceil(label.cell?.cellSize.width ?? label.intrinsicContentSize.width) }

    var fittingWidth: CGFloat {
        Self.clamp(labelLeading + textWidth + Self.labelInset) + (indicator == nil ? 0 : Self.indicatorSlotGrowth)
    }

    static func clamp(_ width: CGFloat) -> CGFloat { min(max(width, minWidth), maxChipWidth) }

    private var labelLeading: CGFloat {
        process == nil ? Self.labelInset : Self.processInset + Self.processSize.side + Self.processGap
    }

    func reapplyTheme() {
        restyle()
    }

    func restyle() {
        let chrome = Theme.current.chrome
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        paragraph.alignment = process == nil ? .center : .left
        let styled = NSAttributedString(
            string: title,
            attributes: [
                .font: Self.chipFont, .kern: Self.titleKern, .paragraphStyle: paragraph,
                .foregroundColor: chrome.ink(isCurrent || showsHover ? .normal : .subtle),
            ])
        if label.attributedStringValue != styled {
            label.attributedStringValue = styled
            needsLayout = true
        }
        if let process { processBadge.show(process) }
        processBadge.isHidden = process == nil
        if case .dot(let state) = indicator {
            dot.state = state
        } else {
            dot.state = nil
        }
        easeFill(showsHover && !isCurrent ? chrome.fill(.hover) : .clear)
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
        let passive: [NSView] = [processBadge, labelContainer, dot, spinner]
        return passive.contains { hit === $0 || hit.isDescendant(of: $0) } ? self : hit
    }

    override func layout() {
        super.layout()
        let slot = closeSlot
        dot.frame = CGRect(
            x: slot.midX - StateDot.diameter / 2, y: slot.midY - StateDot.diameter / 2,
            width: StateDot.diameter, height: StateDot.diameter)
        let spin = spinner.intrinsicContentSize
        spinner.frame = CGRect(
            x: slot.midX - spin.width / 2, y: slot.midY - spin.height / 2, width: spin.width, height: spin.height)
        let side = Self.processSize.side
        let trailing = indicator == nil ? bounds.width - Self.labelInset : slot.minX
        let centering = process == nil ? 0 : max(0, (trailing - labelLeading - textWidth) / 2)
        processBadge.frame = CGRect(
            x: Self.processInset + centering, y: (bounds.height - side) / 2, width: side, height: side)
        let labelX = labelLeading + centering
        labelFrame = CGRect(x: labelX, y: 0, width: max(0, trailing - labelX), height: bounds.height)
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
        dot.isHidden = dot.state == nil || closing
        spinner.isHidden = indicator != .spinner || closing
        spinner.isSpinning = !spinner.isHidden
        guard closing, labelFrame.width > 0, closeSlot.minX < labelFrame.maxX else {
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
