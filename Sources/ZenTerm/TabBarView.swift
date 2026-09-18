import AppKit
import TabKit

enum TabAttentionState {
    case idle, completed, waiting
}

struct TabBarItem {
    let id: TabID
    let index: Int
    let title: String
    let isActive: Bool
    let attentionState: TabAttentionState
}

// Chips are framed by hand: inside a scroll view an `NSStackView`'s intrinsic width is not authoritative.
final class TabBarView: NSView {
    private let onSelect: (TabID) -> Void
    private let onClose: (TabID) -> Void
    private let onRename: (TabID) -> Void

    static let height: CGFloat = 30

    private static let leadingInset: CGFloat = 12
    private static let chipSpacing: CGFloat = 4
    private static let chipHeight: CGFloat = 22
    private static let bandNudge: CGFloat = 6
    private static let fadeWidth: CGFloat = 28

    static let chipFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
    // The rename editor matches it, or the text reflows on open.
    static let titleKern: CGFloat = 0.4
    fileprivate static let labelInset: CGFloat = 9
    static let maxChipWidth: CGFloat = 220

    fileprivate static var activeInk: NSColor { Theme.current.chrome.ink(.normal) }
    fileprivate static var idleInk: NSColor {
        Theme.current.chrome.ink(.subtle)
    }
    static var activeInkForTesting: NSColor { activeInk }
    static var idleInkForTesting: NSColor { idleInk }

    private let scrollView = NSScrollView()
    private let docView = NSView()
    // Kept per tab across renders: rebuilding blinked the hovered chip's tooltip on every title poll.
    private var chips: [Chip] = []
    // Alpha-only mask, so it is theme-independent.
    private let edgeFade = CAGradientLayer()
    private let tracer = CALayer()
    private var activeTabID: TabID?
    // A move changes the slot but not the active tab; only this separates it from a title poll.
    private var activeTabIndex: Int?
    private var lastItems: [TabBarItem] = []
    // Matches the canvas page-slide so the two land together.
    private static let tracerDuration: CFTimeInterval = 0.28

    init(
        onSelect: @escaping (TabID) -> Void,
        onClose: @escaping (TabID) -> Void,
        onRename: @escaping (TabID) -> Void
    ) {
        self.onSelect = onSelect
        self.onClose = onClose
        self.onRename = onRename
        super.init(frame: .zero)
        wantsLayer = true

        docView.wantsLayer = true
        docView.layer?.addSublayer(tracer)

        scrollView.wantsLayer = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.horizontalScrollElasticity = .allowed
        scrollView.verticalScrollElasticity = .none
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = .init()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = docView
        scrollView.layer?.mask = edgeFade
        edgeFade.startPoint = CGPoint(x: 0, y: 0.5)
        edgeFade.endPoint = CGPoint(x: 1, y: 0.5)
        addSubview(scrollView)

        let clip = scrollView.contentView
        clip.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(clipBoundsChanged),
            name: NSView.boundsDidChangeNotification, object: clip)

        tracer.backgroundColor = Theme.current.chrome.accent.nsColor.cgColor
        tracer.cornerRadius = 1
        tracer.anchorPoint = CGPoint(x: 0, y: 0.5)
        tracer.zPosition = 1
        tracer.isHidden = true

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.heightAnchor.constraint(equalToConstant: Self.chipHeight),
            scrollView.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -Self.bandNudge),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit { NotificationCenter.default.removeObserver(self) }

    func render(_ items: [TabBarItem]) {
        lastItems = items
        var reusable = Dictionary(uniqueKeysWithValues: chips.map { ($0.id, $0) })
        var next: [Chip] = []
        var activeChip: Chip?
        for item in items {
            let id = item.id
            let chip =
                reusable.removeValue(forKey: id)
                ?? {
                    let fresh = Chip(
                        id: id, attributed: Self.tabLabel(item), index: item.index,
                        onClick: { [weak self] in self?.onSelect(id) },
                        onMiddleClick: { [weak self] in self?.onClose(id) },
                        onDoubleClick: { [weak self] in self?.onRename(id) })
                    docView.addSubview(fresh)
                    return fresh
                }()
            chip.update(attributed: Self.tabLabel(item), index: item.index)
            next.append(chip)
            if item.isActive { activeChip = chip }
        }
        reusable.values.forEach { $0.removeFromSuperview() }
        chips = next
        layoutChips()

        let newActive = items.first(where: \.isActive)?.id
        if let activeChip {
            let selectionChanged = activeTabID != newActive
            let newIndex = items.first(where: \.isActive)?.index
            let slotChanged = activeTabIndex != nil && activeTabIndex != newIndex
            moveTracer(to: tracerFrame(for: activeChip), animated: activeTabID != nil && selectionChanged)
            tracer.isHidden = false
            if selectionChanged || slotChanged {
                activeChip.scrollToVisible(activeChip.bounds.insetBy(dx: -Self.fadeWidth, dy: 0))
            }
            activeTabIndex = newIndex
        } else {
            tracer.isHidden = true
            activeTabIndex = nil
        }
        activeTabID = newActive
        updateFade()
        refreshHover()
    }

    func reapplyTheme() {
        tracer.backgroundColor = Theme.current.chrome.accent.nsColor.cgColor
        chips.forEach { $0.reapplyTheme() }
        render(lastItems)
    }

    var chipsForTesting: [NSView] { chips }

    var chipLabelsForTesting: [NSAttributedString] { chips.map(\.attributedLabelForTesting) }

    var tracerColorForTesting: NSColor? { tracer.backgroundColor.flatMap { NSColor(cgColor: $0) } }

    var isOverflowFadedForTesting: Bool { hasRightOverflow }

    var isLeadingFadedForTesting: Bool { hasLeftOverflow }

    static func tabLabelStringForTesting(_ item: TabBarItem) -> String { tabLabel(item).string }

    var chipTooltipsForTesting: [(label: String, shortcut: String?)] {
        chips.map { ($0.tooltipLabelForTesting, $0.tooltipShortcutForTesting) }
    }

    var visibleStripRectForTesting: CGRect { scrollView.contentView.documentVisibleRect }

    func scrollToForTesting(x: CGFloat) {
        let clip = scrollView.contentView
        clip.scroll(to: CGPoint(x: x, y: 0))
        scrollView.reflectScrolledClipView(clip)
        updateFade()
    }

    override func layout() {
        super.layout()
        layoutChips()
        clampScrollIfContentFits()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        edgeFade.frame = scrollView.bounds
        let w = scrollView.bounds.width
        let f = w > 2 * Self.fadeWidth ? Double(Self.fadeWidth / w) : 0
        edgeFade.locations = [0, NSNumber(value: f), NSNumber(value: 1 - f), 1]
        CATransaction.commit()
        updateFade()
    }

    private func layoutChips() {
        let h = scrollView.contentView.bounds.height > 0 ? scrollView.contentView.bounds.height : Self.chipHeight
        let chipY = (h - Self.chipHeight) / 2
        var x = Self.leadingInset
        for chip in chips {
            let width = chip.fittingWidth
            chip.frame = CGRect(x: x, y: chipY, width: width, height: Self.chipHeight)
            x += width + Self.chipSpacing
        }
        let contentWidth = chips.isEmpty ? 0 : x - Self.chipSpacing
        docView.frame = CGRect(x: 0, y: 0, width: contentWidth, height: h)
    }

    private func clampScrollIfContentFits() {
        let clip = scrollView.contentView
        if docView.frame.width <= clip.bounds.width, clip.bounds.origin.x > 0 {
            clip.scroll(to: .zero)
            scrollView.reflectScrolledClipView(clip)
        }
    }

    @objc private func clipBoundsChanged() {
        updateFade()
        refreshHover()
    }

    // Per-chip tracking areas miss `mouseExited` when chips scroll under a stationary cursor.
    private func refreshHover() {
        guard let window, window.isKeyWindow else {
            chips.forEach { $0.setHover(false) }
            return
        }
        let mouse = window.mouseLocationOutsideOfEventStream
        let visible = scrollView.contentView.documentVisibleRect
        for chip in chips {
            let underPointer = chip.frame.intersects(visible) && chip.convert(chip.bounds, to: nil).contains(mouse)
            chip.setHover(underPointer)
        }
    }

    private var hasRightOverflow: Bool {
        let clip = scrollView.contentView
        let visibleMaxX = clip.bounds.origin.x + clip.bounds.width
        return docView.frame.width - visibleMaxX > 0.5
    }

    private var hasLeftOverflow: Bool {
        scrollView.contentView.bounds.origin.x > 0.5
    }

    private func updateFade() {
        let opaque = CGColor(gray: 1, alpha: 1)
        let clear = CGColor(gray: 1, alpha: 0)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        edgeFade.colors = [
            hasLeftOverflow ? clear : opaque, opaque, opaque, hasRightOverflow ? clear : opaque,
        ]
        CATransaction.commit()
    }

    private func tracerFrame(for chip: NSView) -> CGRect {
        CGRect(x: chip.frame.minX + 9, y: 0, width: chip.frame.width - 18, height: 2)
    }

    private func setTracerFrame(_ frame: CGRect) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tracer.frame = frame
        CATransaction.commit()
    }

    private func moveTracer(to target: CGRect, animated: Bool) {
        guard animated, !Motion.isReduceMotionEnabled() else {
            setTracerFrame(target)
            return
        }
        let start = tracer.presentation()?.frame ?? tracer.frame
        setTracerFrame(target)

        let movingRight = target.midX >= start.midX
        let leftValues: [CGFloat] =
            movingRight
            ? [start.minX, start.minX, target.minX] : [start.minX, target.minX, target.minX]
        let widthValues: [CGFloat] =
            movingRight
            ? [start.width, target.maxX - start.minX, target.width]
            : [start.width, start.maxX - target.minX, target.width]

        let left = CAKeyframeAnimation(keyPath: "position.x")
        left.values = leftValues.map { $0 as NSNumber }
        let width = CAKeyframeAnimation(keyPath: "bounds.size.width")
        width.values = widthValues.map { $0 as NSNumber }
        for anim in [left, width] {
            anim.keyTimes = [0, 0.5, 1]
            anim.duration = Self.tracerDuration
            anim.timingFunctions = [
                CAMediaTimingFunction(name: .easeOut),
                CAMediaTimingFunction(name: .easeInEaseOut),
            ]
        }
        tracer.add(left, forKey: "tracer.left")
        tracer.add(width, forKey: "tracer.width")
    }

    private static func tabLabel(_ item: TabBarItem) -> NSAttributedString {
        let font = chipFont
        let ink = item.isActive ? activeInk : idleInk
        let numberColor: NSColor
        switch item.attentionState {
        case .idle: numberColor = ink
        case .completed: numberColor = Theme.current.chrome.positive.nsColor
        case .waiting: numberColor = Theme.current.chrome.attention.nsColor
        }
        let prefix = "\(item.index) "
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let s = NSMutableAttributedString(
            string: prefix,
            attributes: [
                .font: font, .foregroundColor: numberColor, .paragraphStyle: paragraph,
            ])
        s.append(
            NSAttributedString(
                string: item.title,
                attributes: [
                    .font: font, .foregroundColor: ink, .kern: titleKern,
                    .paragraphStyle: paragraph,
                ]))
        return s
    }

    private final class Chip: NSView {
        let id: TabID
        private var tabIndex: Int
        private let onClick: () -> Void
        private let onMiddleClick: (() -> Void)?
        private let onDoubleClick: (() -> Void)?
        private var isHovered = false
        private let label: NSTextField
        private lazy var tooltip = TooltipHost(label: "Focus tab") { [weak self] in
            guard let self, self.tabIndex <= 9 else { return nil }
            return CommandCatalog.spec(for: .selectTab(self.tabIndex)).shortcut
        }

        var fittingWidth: CGFloat {
            min(
                label.intrinsicContentSize.width + 2 * TabBarView.labelInset,
                TabBarView.maxChipWidth)
        }

        var attributedLabelForTesting: NSAttributedString { label.attributedStringValue }

        var tooltipLabelForTesting: String { tooltip.label }
        var tooltipShortcutForTesting: String? { tooltip.shortcutForTesting }

        init(
            id: TabID, attributed: NSAttributedString, index: Int,
            onClick: @escaping () -> Void, onMiddleClick: (() -> Void)?,
            onDoubleClick: (() -> Void)?
        ) {
            self.id = id
            self.tabIndex = index
            self.onClick = onClick
            self.onMiddleClick = onMiddleClick
            self.onDoubleClick = onDoubleClick
            label = NSTextField(labelWithAttributedString: attributed)
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            super.init(frame: .zero)
            wantsLayer = true
            layer?.cornerRadius = 6

            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)

            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: TabBarView.labelInset),
                label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -TabBarView.labelInset),
                label.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        func update(attributed: NSAttributedString, index: Int) {
            tabIndex = index
            guard label.attributedStringValue != attributed else { return }
            label.attributedStringValue = attributed
            needsLayout = true
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(
                NSTrackingArea(
                    rect: bounds,
                    options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                    owner: self))
        }

        override func mouseEntered(with event: NSEvent) { setHover(true) }
        override func mouseExited(with event: NSEvent) { setHover(false) }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { tooltip.hide(from: self) }
        }

        func setHover(_ on: Bool) {
            guard isHovered != on else { return }
            isHovered = on
            updateBackground()
            if on { tooltip.show(from: self) } else { tooltip.hide(from: self) }
        }
        override func mouseDown(with event: NSEvent) {
            tooltip.hide(from: self)
            if event.clickCount == 2 { onDoubleClick?() } else { onClick() }
        }
        override func otherMouseDown(with event: NSEvent) {
            if event.buttonNumber == 2 { onMiddleClick?() }
        }

        func reapplyTheme() {
            updateBackground()
        }

        private func updateBackground() {
            guard let layer else { return }
            Motion.ease(
                layer, keyPath: "backgroundColor",
                to: (isHovered ? Theme.current.chrome.fill(.hover) : .clear).cgColor)
        }
    }
}
