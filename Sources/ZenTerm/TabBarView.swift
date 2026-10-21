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
    private let directory: (TabID) -> URL?

    static let height: CGFloat = ChromeMetrics.Height.lg

    static let leadingInset: CGFloat = ChromeMetrics.Spacing.s12
    private static let chipSpacing: CGFloat = ChromeMetrics.Spacing.s4
    // The floating sidebar keeps its own toggle this far above the card's bottom, matching the docked one's band.
    static let chipBandInset: CGFloat = (height + ChromeMetrics.footerGap) / 2

    private let scrollView = FadingScrollView(axis: .horizontal)
    private let docView = NSView()
    // Kept per tab across renders: rebuilding blinked the hovered chip's tooltip on every title poll.
    private var chips: [TerminalTabChip] = []
    private let pill = CALayer()
    private var activeTabID: TabID?
    // A move changes the slot but not the active tab; only this separates it from a title poll.
    private var activeTabIndex: Int?
    private var lastItems: [TabBarItem] = []

    init(
        onSelect: @escaping (TabID) -> Void,
        onClose: @escaping (TabID) -> Void,
        onRename: @escaping (TabID) -> Void,
        directory: @escaping (TabID) -> URL? = { _ in nil }
    ) {
        self.onSelect = onSelect
        self.onClose = onClose
        self.onRename = onRename
        self.directory = directory
        super.init(frame: .zero)
        wantsLayer = true

        docView.wantsLayer = true
        docView.layer?.insertSublayer(pill, at: 0)

        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.horizontalScrollElasticity = .allowed
        scrollView.verticalScrollElasticity = .none
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = docView
        addSubview(scrollView)

        let clip = scrollView.contentView
        clip.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(clipBoundsChanged),
            name: NSView.boundsDidChangeNotification, object: clip)

        pill.backgroundColor = Theme.current.chrome.fill(.active).cgColor
        pill.cornerRadius = ChromeMetrics.Radius.control
        pill.anchorPoint = CGPoint(x: 0, y: 0.5)
        pill.zPosition = -1
        pill.isHidden = true

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.heightAnchor.constraint(equalToConstant: TabChip.height),
            scrollView.centerYAnchor.constraint(equalTo: bottomAnchor, constant: -Self.chipBandInset),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit { NotificationCenter.default.removeObserver(self) }

    var chipBandCenterYAnchor: NSLayoutYAxisAnchor { scrollView.centerYAnchor }

    func render(_ items: [TabBarItem]) {
        lastItems = items
        var reusable = Dictionary(uniqueKeysWithValues: chips.map { ($0.id, $0) })
        var next: [TerminalTabChip] = []
        var activeChip: TerminalTabChip?
        for item in items {
            let id = item.id
            let chip =
                reusable.removeValue(forKey: id)
                ?? {
                    let fresh = TerminalTabChip(
                        id: id, index: item.index,
                        onClick: { [weak self] in self?.onSelect(id) },
                        onClose: { [weak self] in self?.onClose(id) },
                        onDoubleClick: { [weak self] in self?.onRename(id) },
                        directory: { [weak self] in self?.directory(id) })
                    docView.addSubview(fresh)
                    return fresh
                }()
            chip.update(
                index: item.index, title: item.title, isCurrent: item.isActive,
                dotColor: Self.dotColor(for: item.attentionState))
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
            Motion.stretch(pill, to: activeChip.frame, animated: activeTabID != nil && selectionChanged)
            pill.isHidden = false
            if selectionChanged || slotChanged {
                scrollView.reveal(activeChip)
            }
            activeTabIndex = newIndex
        } else {
            pill.isHidden = true
            activeTabIndex = nil
        }
        activeTabID = newActive
        refreshHover()
    }

    func reapplyTheme() {
        pill.backgroundColor = Theme.current.chrome.fill(.active).cgColor
        chips.forEach { $0.reapplyTheme() }
        render(lastItems)
    }

    var chipsForTesting: [TerminalTabChip] { chips }

    var chipLabelsForTesting: [NSAttributedString] { chips.map(\.attributedLabelForTesting) }

    var pillColorForTesting: NSColor? { pill.backgroundColor.flatMap { NSColor(cgColor: $0) } }

    var pillFrameForTesting: CGRect { pill.frame }

    var isOverflowFadedForTesting: Bool { scrollView.fadedEdgesForTesting.end }

    var isLeadingFadedForTesting: Bool { scrollView.fadedEdgesForTesting.start }

    var chipTooltipsForTesting: [(label: String?, shortcut: String?)] {
        chips.map { ($0.tooltipLabelForTesting, $0.tooltipShortcutForTesting) }
    }

    var visibleStripRectForTesting: CGRect { scrollView.contentView.documentVisibleRect }

    func scrollToForTesting(x: CGFloat) {
        let clip = scrollView.contentView
        clip.scroll(to: CGPoint(x: x, y: 0))
        scrollView.reflectScrolledClipView(clip)
    }

    override func layout() {
        super.layout()
        layoutChips()
        clampScrollIfContentFits()
    }

    private func layoutChips() {
        let h = scrollView.contentView.bounds.height > 0 ? scrollView.contentView.bounds.height : TabChip.height
        let chipY = (h - TabChip.height) / 2
        var x = Self.leadingInset
        for chip in chips {
            let width = chip.fittingWidth
            chip.frame = CGRect(x: x, y: chipY, width: width, height: TabChip.height)
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
        refreshHover()
    }

    // Per-chip tracking areas miss `mouseExited` when chips scroll under a stationary cursor.
    private func refreshHover() {
        guard let window, window.isKeyWindow else {
            chips.forEach { $0.setHover(isPinnedHover($0.id)) }
            return
        }
        let mouse = window.mouseLocationOutsideOfEventStream
        let visible = scrollView.contentView.documentVisibleRect
        for chip in chips {
            let underPointer = chip.frame.intersects(visible) && chip.convert(chip.bounds, to: nil).contains(mouse)
            chip.setHover(underPointer || isPinnedHover(chip.id))
        }
    }

    #if DEBUG
        private var pinnedHoverForGallery: TabID?

        func forceHoverForGallery(tab: TabID) {
            pinnedHoverForGallery = tab
            refreshHover()
        }
    #endif

    private func isPinnedHover(_ id: TabID) -> Bool {
        #if DEBUG
            return id == pinnedHoverForGallery
        #else
            return false
        #endif
    }

    private static func dotColor(for state: TabAttentionState) -> NSColor? {
        let chrome = Theme.current.chrome
        switch state {
        case .idle: return nil
        case .completed: return chrome.positive.nsColor
        case .waiting: return chrome.attention.nsColor
        }
    }
}
