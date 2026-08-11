import AppKit

struct CheckboxDropdownItem: Equatable {
    let title: String
    let isChecked: Bool
}

/// A themed dropdown whose open list is a row of real checkboxes — the chrome's multi-select
/// control. Closed, it reads like `Dropdown`: a compact button with a summary title and chevron,
/// bubbling Up/Down to the form as one focus stop. Return/Space/click opens the floating list;
/// Up/Down move the highlight, Space/Return toggle the highlighted row, and a click toggles its
/// row — the list STAYS open on a toggle, because a multi-select is several picks per visit.
/// Esc, an outside click (focus loss), or leaving the window closes it.
///
/// The control renders state it never owns: `onToggle` reports the toggled index and the owner
/// re-syncs via `setItems` once the write lands, which re-renders the open rows in place.
final class CheckboxDropdown: NSView {
    private(set) var items: [CheckboxDropdownItem]
    private let onToggle: (Int) -> Void
    /// The row count is fixed at init — this list renders a static catalog whose checked states
    /// move. `setItems` clamps to it, so a longer array can never outgrow the built rows (arrowing
    /// past the last rendered row would toggle entries the user cannot see).
    private let rowCount: Int

    var onArrowUp: (() -> Void)?
    var onArrowDown: (() -> Void)?
    var onArrowLeft: (() -> Void)?
    var onTab: (() -> Void)?
    var onBacktab: (() -> Void)?

    private let titleLabel = NSTextField(labelWithString: "")
    /// Retained (not a throwaway init-local) so `reapplyTheme()` can re-tint it on a theme swap.
    private let chevron = NSImageView()
    private var listCard: NSView?
    private var rowViews: [CheckboxRowView] = []
    private var highlighted = 0
    private var isFocusedStop = false

    private static var restFill: NSColor { Theme.current.chrome.ink(alpha: 0.06) }
    private static var focusFill: NSColor { PaletteOverlay.selectionBackground }
    private static let rowHeight: CGFloat = 28
    private static let maxListHeight: CGFloat = 260

    // MARK: test hooks

    var buttonTitleForTesting: String { titleLabel.stringValue }
    var itemsForTesting: [CheckboxDropdownItem] { items }
    var isPopoverOpen: Bool { listCard != nil }
    var highlightedIndexForTesting: Int { highlighted }
    /// The open list's row views in list order, for click tests that drive a row's real `mouseDown`.
    var rowViewsForTesting: [NSView] { rowViews }
    func openListForTesting() { openList() }
    var listCardSizeForTesting: NSSize { listCard?.frame.size ?? .zero }

    init(title: String, items: [CheckboxDropdownItem], onToggle: @escaping (Int) -> Void) {
        self.items = items
        self.rowCount = items.count
        self.onToggle = onToggle
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.backgroundColor = Self.restFill.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = Theme.current.chrome.ink(alpha: 0.10).cgColor

        titleLabel.font = .systemFont(ofSize: 13)
        titleLabel.textColor = Theme.current.chrome.foreground.nsColor
        titleLabel.stringValue = title
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.lineBreakMode = .byTruncatingTail

        chevron.image = NSImage(systemSymbolName: "chevron.up.chevron.down", accessibilityDescription: nil)
        chevron.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
        chevron.contentTintColor = Theme.current.chrome.ink(alpha: 0.5)
        chevron.translatesAutoresizingMaskIntoConstraints = false

        addSubview(titleLabel)
        addSubview(chevron)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 30),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevron.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 6),
            chevron.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Programmatic sync after a config reload — never fires `onToggle`, and an open list re-renders
    /// its rows in place (a toggle's own reload lands here, and closing on it would eject the user
    /// mid-multi-select). Clamped to the init row count; see `rowCount`.
    func setItems(_ items: [CheckboxDropdownItem], title: String) {
        self.items = Array(items.prefix(rowCount))
        titleLabel.stringValue = title
        refreshRows()
    }

    /// Re-apply the live chrome colors after a config change — no relaunch. The open list is
    /// rebuilt fresh (reading `Theme.current`) on every open, so only the button needs recoloring.
    func reapplyTheme() {
        restyle()
        titleLabel.textColor = Theme.current.chrome.foreground.nsColor
        chevron.contentTintColor = Theme.current.chrome.ink(alpha: 0.5)
    }

    // MARK: focus

    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool {
        isFocusedStop = true
        restyle()
        return true
    }
    override func resignFirstResponder() -> Bool {
        isFocusedStop = false
        closeList()
        restyle()
        return super.resignFirstResponder()
    }
    override func drawFocusRingMask() {}

    /// The open list card is parented to the window's content view (so it escapes this control's
    /// bounds), not to this subtree — so tearing out an ancestor (the Settings modal) can't strand
    /// a dead list over every tab. Same lifetime binding as `Dropdown`.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { closeList() }
    }

    private func restyle() {
        let chrome = Theme.current.chrome
        let open = listCard != nil
        layer?.backgroundColor = (isFocusedStop || open ? Self.focusFill : Self.restFill).cgColor
        layer?.borderColor = (isFocusedStop || open ? chrome.accent.nsColor : chrome.ink(alpha: 0.10)).cgColor
        layer?.borderWidth = isFocusedStop || open ? 1.5 : 1
    }

    // MARK: keyboard

    override func keyDown(with event: NSEvent) {
        if listCard != nil {
            switch KeyboardFocus.key(for: event) {
            case .up: moveHighlight(-1)
            case .down: moveHighlight(1)
            case .activate: toggleHighlight()  // return / enter / space — the list stays open
            // Local Esc is what makes layered dismissal work: it reaches this keyDown before any
            // card-root performKeyEquivalent, so the list closes and the Settings card stays.
            case .escape: closeList()
            default: break  // consume every other key while the list is open
            }
            return
        }
        switch KeyboardFocus.key(for: event) {
        case .activate: openList()  // return / enter / space
        case .up: onArrowUp?()
        case .down: onArrowDown?()
        case .left where onArrowLeft != nil: onArrowLeft?()
        case .tab(let shift): shift ? onBacktab?() : onTab?()
        default: super.keyDown(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        listCard == nil ? openList() : closeList()
    }

    /// The whole control is one click target — without this the title label and chevron swallow
    /// the click and only the padding gaps would open the list.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, alphaValue > 0 else { return nil }
        return bounds.contains(convert(point, from: superview)) ? self : nil
    }

    // MARK: list

    private func openList() {
        guard listCard == nil, window?.contentView != nil else { return }
        highlighted = 0
        let card = buildListCard()
        window?.contentView?.addSubview(card)
        listCard = card
        // After the assignment: `refreshRows` gates the highlight on `listCard != nil`, so painting
        // from inside `buildListCard` would leave the first row unhighlighted until an arrow moves.
        refreshRows()
        positionList()
        restyle()
    }

    private func closeList() {
        listCard?.removeFromSuperview()
        listCard = nil
        rowViews = []
        restyle()
    }

    private func moveHighlight(_ delta: Int) {
        guard let next = KeyboardFocus.step(from: highlighted, delta: delta, count: items.count) else { return }
        highlighted = next
        refreshRows()
        guard rowViews.indices.contains(highlighted) else { return }
        let row = rowViews[highlighted]
        row.scrollToVisible(row.bounds)
    }

    private func toggleHighlight() { toggle(highlighted) }

    /// Report a toggle and keep the list open — several picks per visit is the point of a
    /// multi-select. The owner's write triggers a reload whose `setItems` re-renders the rows.
    private func toggle(_ index: Int) {
        guard items.indices.contains(index) else { return }
        highlighted = index
        onToggle(index)
        refreshRows()
    }

    private func refreshRows() {
        let chrome = Theme.current.chrome
        for (index, row) in rowViews.enumerated() {
            guard items.indices.contains(index) else { continue }
            row.render(
                item: items[index], isHighlighted: listCard != nil && index == highlighted,
                chrome: chrome)
        }
    }

    // Build + position mirror `Dropdown`'s window-child pattern: a FloatShadow-chromed card
    // holding a capped-height scroll of row views, framed below the button (flipping above when
    // the window bottom is near).
    private func buildListCard() -> NSView {
        let chrome = Theme.current.chrome
        let width = max(bounds.width, 180)

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false

        rowViews = []
        var contentHeight: CGFloat = 0
        for index in items.indices {
            if contentHeight > 0 { contentHeight += stack.spacing }
            let row = CheckboxRowView { [weak self] in self?.toggle(index) }
            stack.addArrangedSubview(row)
            row.heightAnchor.constraint(equalToConstant: Self.rowHeight).isActive = true
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            rowViews.append(row)
            contentHeight += Self.rowHeight
        }

        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.verticalScroller = SlimScroller()
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.documentView = doc
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let card = ShadowCardView()
        card.wantsLayer = true
        card.layer?.cornerRadius = 8
        card.layer?.backgroundColor = chrome.background.nsColor.cgColor
        card.layer?.borderWidth = 1
        card.layer?.borderColor = FloatShadow.edge.cgColor
        // Frame-driven, like Dropdown's card: positioned AND sized by frame in positionList.
        card.translatesAutoresizingMaskIntoConstraints = true
        FloatShadow.applyShadow(to: card)
        card.addSubview(scroll)

        let insets: CGFloat = 6
        let cardHeight = min(contentHeight + insets * 2, Self.maxListHeight)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: card.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.topAnchor.constraint(equalTo: doc.topAnchor, constant: insets),
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -8),
            stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -insets),
        ])
        card.frame = NSRect(x: 0, y: 0, width: width, height: cardHeight)
        return card
    }

    private func positionList() {
        guard let card = listCard, let contentView = window?.contentView else { return }
        card.layoutSubtreeIfNeeded()
        let size = card.frame.size
        let origin = convert(bounds, to: contentView)
        let x = max(8, min(origin.minX, contentView.bounds.width - size.width - 8))
        // contentView is not flipped: below the button = a smaller y. Prefer below; if that runs
        // off the bottom, flip above, then clamp so the card never draws outside the window.
        let below = origin.minY - size.height - 4
        let above = origin.maxY + 4
        let maxY = max(8, contentView.bounds.height - size.height - 8)
        var y = below
        if y < 8 { y = above }
        y = max(8, min(y, maxY))
        card.frame = NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// One checkbox row in the open list: a fixed-width check slot (titles align whether checked
    /// or not) and the title. Checked rows show an accent check and full-strength title; unchecked
    /// rows dim the title. The keyboard highlight fills like a `Dropdown` row.
    private final class CheckboxRowView: NSView {
        private let onClick: () -> Void
        private let check = NSImageView()
        private let title = NSTextField(labelWithString: "")

        init(onClick: @escaping () -> Void) {
            self.onClick = onClick
            super.init(frame: .zero)
            wantsLayer = true
            layer?.cornerRadius = 5
            translatesAutoresizingMaskIntoConstraints = false

            check.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)
            check.symbolConfiguration = .init(pointSize: 11, weight: .semibold)
            check.translatesAutoresizingMaskIntoConstraints = false
            title.font = .systemFont(ofSize: 13)
            title.lineBreakMode = .byTruncatingTail
            title.translatesAutoresizingMaskIntoConstraints = false
            addSubview(check)
            addSubview(title)
            NSLayoutConstraint.activate([
                check.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
                check.widthAnchor.constraint(equalToConstant: 14),
                check.centerYAnchor.constraint(equalTo: centerYAnchor),
                title.leadingAnchor.constraint(equalTo: check.trailingAnchor, constant: 6),
                title.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
                title.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        func render(item: CheckboxDropdownItem, isHighlighted: Bool, chrome: ChromeTheme) {
            title.stringValue = item.title
            title.textColor = item.isChecked ? chrome.foreground.nsColor : chrome.ink(alpha: 0.5)
            check.isHidden = !item.isChecked
            check.contentTintColor = chrome.accent.nsColor
            layer?.backgroundColor = (isHighlighted ? chrome.ink(alpha: 0.10) : NSColor.clear).cgColor
        }

        override func mouseDown(with event: NSEvent) { onClick() }
    }
}
