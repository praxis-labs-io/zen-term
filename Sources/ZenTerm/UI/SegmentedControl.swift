import AppKit

final class SegmentedControl: ControlView, ThemeReapplying {
    private(set) var selectedIndex: Int
    private(set) var optionTitles: [String]
    var onChange: (Int) -> Void
    var onArrowUp: (() -> Void)?
    var onArrowDown: (() -> Void)?
    var onArrowLeft: (() -> Void)?
    var onTab: (() -> Void)?
    var onBacktab: (() -> Void)?

    var isEnabled = true {
        didSet {
            guard isEnabled != oldValue else { return }
            segments.forEach { $0.isEnabled = isEnabled }
            if !isEnabled, hasKeyboardFocus { window?.makeFirstResponder(nil) }
            restyle()
        }
    }

    private static let inset = ChromeMetrics.Spacing.s2
    private static let trackHeight = ChromeMetrics.Height.control
    private var segments: [Segment] = []
    // A layer the control owns, so the slide drives its geometry.
    private let selectedSurface = CALayer()
    // Lets a reselect pin a value that is only OS-derived, as the reduce-motion row needs.
    private let notifiesOnReselect: Bool

    init(
        options: [String], selectedIndex: Int = 0, notifiesOnReselect: Bool = false,
        onChange: @escaping (Int) -> Void
    ) {
        self.optionTitles = options
        self.selectedIndex = min(max(selectedIndex, 0), max(options.count - 1, 0))
        self.notifiesOnReselect = notifiesOnReselect
        self.onChange = onChange
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = ChromeMetrics.Radius.capsule(Self.trackHeight)
        translatesAutoresizingMaskIntoConstraints = false

        setAccessibilityElement(true)
        setAccessibilityRole(.radioGroup)
        selectedSurface.anchorPoint = CGPoint(x: 0, y: 0.5)
        selectedSurface.cornerRadius = ChromeMetrics.Radius.capsule(ChromeMetrics.Height.sm)
        selectedSurface.zPosition = -1
        layer?.insertSublayer(selectedSurface, at: 0)

        segments = options.enumerated().map { index, title in
            Segment(title: title) { [weak self] in self?.select(index) }
        }
        var leading = leadingAnchor
        var leadingInset = Self.inset
        for segment in segments {
            addSubview(segment)
            NSLayoutConstraint.activate([
                segment.leadingAnchor.constraint(equalTo: leading, constant: leadingInset),
                segment.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
            leading = segment.trailingAnchor
            leadingInset = 0
        }
        heightAnchor.constraint(equalToConstant: Self.trackHeight).isActive = true
        if let last = segments.last {
            last.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Self.inset).isActive = true
        }
        restyle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // Without an intrinsic width the control stretches to fill its row instead of hugging its segments.
    override var intrinsicContentSize: NSSize {
        let segmentsWidth = segments.reduce(0) { $0 + $1.fittingSize.width }
        return NSSize(width: segmentsWidth + Self.inset * 2, height: Self.trackHeight)
    }

    func select(_ index: Int) {
        let clamped = min(max(index, 0), segments.count - 1)
        let changed = clamped != selectedIndex
        selectedIndex = clamped
        restyle()
        placeSelectedSurface(animated: changed)
        guard changed || notifiesOnReselect else { return }
        onChange(clamped)
    }

    func setSelection(_ index: Int) {
        selectedIndex = min(max(index, 0), segments.count - 1)
        restyle()
        placeSelectedSurface(animated: false)
    }

    func reapplyTheme() {
        restyle()
        segments.forEach { $0.restyle() }
    }

    override var acceptsFirstResponder: Bool { isEnabled }

    override func drawFocusRingMask() {}

    override func focusDidChange() { restyle() }

    override func layout() {
        super.layout()
        placeSelectedSurface(animated: false)
    }

    override func keyDown(with event: NSEvent) {
        guard isEnabled else { return super.keyDown(with: event) }
        switch KeyboardFocus.key(for: event) {
        case .left where selectedIndex == 0 && onArrowLeft != nil: onArrowLeft?()
        case .left: select(selectedIndex - 1)
        case .right: select(selectedIndex + 1)
        case .up: onArrowUp?()
        case .down, .activate: onArrowDown?()
        case .tab(let shift) where onTab != nil || onBacktab != nil:
            shift ? onBacktab?() : onTab?()
        default: super.keyDown(with: event)
        }
    }

    private func restyle() {
        layer?.backgroundColor = Theme.current.chrome.fill(.rest).cgColor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        selectedSurface.backgroundColor = Theme.current.chrome.fill(.active).cgColor
        CATransaction.commit()
        showFocusRing(hasKeyboardFocus && isEnabled)
        for (index, segment) in segments.enumerated() { segment.isSelected = index == selectedIndex }
    }

    private func placeSelectedSurface(animated: Bool) {
        guard segments.indices.contains(selectedIndex) else { return }
        Motion.stretch(selectedSurface, to: segments[selectedIndex].frame, animated: animated && window != nil)
    }

    var selectedSurfaceFrameForTesting: CGRect { selectedSurface.frame }
    var selectedSurfaceFillForTesting: CGColor? { selectedSurface.backgroundColor }
    var isSelectedSurfaceSlidingForTesting: Bool { selectedSurface.animation(forKey: "stretch.left") != nil }
    var segmentsForTesting: [NSView] { segments }

    func segmentInkForTesting(_ index: Int) -> NSColor? { segments[index].inkForTesting }
    func segmentFillForTesting(_ index: Int) -> CGColor? { segments[index].layer?.backgroundColor }

    #if DEBUG
        func forceFocusForGallery() { setKeyboardFocus(true) }
        func forceHoverForGallery(segment index: Int) { segments[index].setHovered(true) }
    #endif
}

private final class Segment: ControlView {
    private let label: NSTextField
    private let onPress: () -> Void
    private var isPressed = false

    var isSelected = false { didSet { if isSelected != oldValue { restyle() } } }
    var isEnabled = true {
        didSet {
            guard isEnabled != oldValue else { return }
            if !isEnabled {
                setHovered(false)
                isPressed = false
            }
            window?.invalidateCursorRects(for: self)
            restyle()
        }
    }

    init(title: String, onPress: @escaping () -> Void) {
        label = NSTextField(labelWithString: title)
        self.onPress = onPress
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = ChromeMetrics.Radius.capsule(ChromeMetrics.Height.sm)
        translatesAutoresizingMaskIntoConstraints = false
        label.font = ChromeType.font(.small, weight: .semibold)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(title)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: ChromeMetrics.Height.sm),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: ChromeMetrics.Spacing.controlInset),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -ChromeMetrics.Spacing.controlInset),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        restyle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var inkForTesting: NSColor? { label.textColor }

    override func hoverDidChange() { restyle() }

    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    override func resetCursorRects() {
        if isEnabled { addCursorRect(bounds, cursor: .pointingHand) }
    }

    override func mouseDown(with event: NSEvent) { isPressed = isEnabled }

    override func mouseUp(with event: NSEvent) {
        defer { isPressed = false }
        guard isPressed, isEnabled, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onPress()
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        onPress()
        return true
    }

    func restyle() {
        setAccessibilityValue(isSelected)
        setAccessibilityEnabled(isEnabled)
        let chrome = Theme.current.chrome
        let hovered = showsHover && isEnabled && !isSelected
        let ink: ChromeTheme.InkLevel = !isEnabled ? .faint : (isSelected || hovered ? .normal : .subtle)
        label.textColor = chrome.ink(ink)
        easeFill(hovered ? chrome.fill(.hover) : .clear)
    }
}
