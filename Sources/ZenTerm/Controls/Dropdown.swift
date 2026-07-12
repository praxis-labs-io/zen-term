import AppKit

/// One row in a `Dropdown` menu: a title, an optional group header shown above it, an optional
/// trailing note (e.g. "Light"/"Dark"), and whether it's the current selection (drawn with a check).
struct DropdownItem: Equatable {
    let title: String
    let group: String?
    let note: String?
    let isSelected: Bool
}

/// A keyboard-navigable themed dropdown: a compact button showing the current item; Return/Space/
/// click opens a floating list of rows (grouped headers, trailing notes, a check on the active one).
/// Up/Down move the highlight, Return selects, Esc closes. As a form focus stop it bubbles Up/Down
/// at the list's closed state to the section (like `SegmentedControl`). Styling mirrors `FieldBox`.
final class Dropdown: NSView {
    private(set) var selectedIndex: Int
    private var items: [DropdownItem]
    private let onChange: (Int) -> Void

    var onArrowUp: (() -> Void)?
    var onArrowDown: (() -> Void)?
    var onArrowLeft: (() -> Void)?
    var onTab: (() -> Void)?
    var onBacktab: (() -> Void)?
    var onEsc: (() -> Void)?

    private let titleLabel = NSTextField(labelWithString: "")
    /// Retained (not a throwaway init-local) so `reapplyTheme()` can re-tint it on a theme swap.
    private let chevron = NSImageView()
    private var listCard: NSView?
    private var rowViews: [DropdownRowView] = []
    private var highlighted = 0
    private var isFocusedStop = false

    private static var restFill: NSColor { Theme.current.chrome.ink(alpha: 0.06) }
    private static var focusFill: NSColor { PaletteOverlay.selectionBackground }
    private static let rowHeight: CGFloat = 28
    private static let headerHeight: CGFloat = 20
    private static let maxListHeight: CGFloat = 260

    /// Test hook: the button's current title.
    var buttonTitleForTesting: String { titleLabel.stringValue }

    /// Test hooks: open the floating list and inspect it (there is no other public list API). The
    /// list open-path has no GUI test seam otherwise, and shipped once rendering at zero size.
    func openListForTesting() { openList() }
    var isListOpenForTesting: Bool { listCard != nil }
    var listCardSizeForTesting: NSSize { listCard?.frame.size ?? .zero }
    /// Test hook: drive the highlight the way an arrow key would.
    func moveHighlightForTesting(_ delta: Int) { moveHighlight(delta) }
    /// Test hook: is the highlighted row within its scroll view's visible area right now?
    var isHighlightedRowVisibleForTesting: Bool {
        guard rowViews.indices.contains(highlighted),
            let clip = rowViews[highlighted].enclosingScrollView?.contentView
        else { return false }
        let row = rowViews[highlighted]
        return clip.bounds.intersects(row.convert(row.bounds, to: clip))
    }

    init(items: [DropdownItem], selectedIndex: Int, onChange: @escaping (Int) -> Void) {
        self.items = items
        self.selectedIndex = selectedIndex
        self.onChange = onChange
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.backgroundColor = Self.restFill.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = Theme.current.chrome.ink(alpha: 0.10).cgColor

        titleLabel.font = .systemFont(ofSize: 13)
        titleLabel.textColor = Theme.current.chrome.foreground.nsColor
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
        renderTitle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func setItems(_ items: [DropdownItem], selectedIndex: Int) {
        self.items = items
        self.selectedIndex = min(max(selectedIndex, 0), max(0, items.count - 1))
        renderTitle()
    }

    private func renderTitle() {
        titleLabel.stringValue = items.indices.contains(selectedIndex) ? items[selectedIndex].title : ""
    }

    /// Re-apply the live chrome colors after a config change — no relaunch. `restyle()` already
    /// reads `Theme.current` fresh, but doesn't touch the title/chevron (set once in init); the
    /// open list popover needs nothing here since it's rebuilt fresh (reading Theme fresh) on
    /// every open.
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
            case .activate: commitHighlight()  // return / enter / space
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
        case .escape where onEsc != nil: onEsc?()
        default: super.keyDown(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        listCard == nil ? openList() : closeList()
    }

    /// The whole control is one click target. Without this the title label and chevron subviews
    /// swallow the click (they are `NSControl`/`NSImageView`), so `mouseDown` would only fire in the
    /// padding gaps and clicking the visible text would do nothing.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, alphaValue > 0 else { return nil }
        return bounds.contains(convert(point, from: superview)) ? self : nil
    }

    // MARK: list

    private func openList() {
        guard listCard == nil, window?.contentView != nil else { return }
        highlighted = selectedIndex
        let card = buildListCard()
        window?.contentView?.addSubview(card)
        listCard = card
        positionList()
        scrollHighlightIntoView()  // open scrolled to the current selection when it's below the fold
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
        refreshListHighlight()
        scrollHighlightIntoView()
    }

    /// Keep the highlighted row visible as arrow keys move it past the scroll view's capped height.
    private func scrollHighlightIntoView() {
        guard rowViews.indices.contains(highlighted) else { return }
        let row = rowViews[highlighted]
        row.scrollToVisible(row.bounds)
    }

    private func commitHighlight() {
        selectedIndex = highlighted
        renderTitle()
        closeList()
        onChange(selectedIndex)
        // Keep focus on the dropdown after a pick (keyboard or mouse) so the user can keep
        // arrowing/tabbing from here — a downstream config reload must not pull focus elsewhere.
        window?.makeFirstResponder(self)
    }

    // Build + position + highlight helpers below mirror KeybindHintBubble's window-child pattern:
    // a FloatShadow-chromed vertical stack of row views, each a themed control cell. Rows show an
    // optional faint group header (chrome.ink(alpha:0.4), 10pt semibold), the title, a trailing
    // note (chrome.ink(alpha:0.4)), and a check (SF "checkmark", chrome.accent) when isSelected.
    // The highlighted row fills chrome.ink(alpha:0.10); clicking a row calls commit for its index.
    // positionList(): frame below the button in window coords (convert self.bounds to contentView),
    // width == self bounds width (min 180), capped height with an inner NSScrollView if it overflows.
    private func buildListCard() -> NSView {
        let chrome = Theme.current.chrome
        let width = max(bounds.width, 180)

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false

        rowViews = []
        var previousGroup: String?
        var contentHeight: CGFloat = 0
        for (index, item) in items.enumerated() {
            if let group = item.group, group != previousGroup {
                if contentHeight > 0 { contentHeight += stack.spacing }
                stack.addArrangedSubview(Self.groupHeaderView(group, chrome: chrome))
                contentHeight += Self.headerHeight
            }
            previousGroup = item.group
            if contentHeight > 0 { contentHeight += stack.spacing }
            let row = DropdownRowView(index: index, item: item, chrome: chrome) { [weak self] i in
                self?.highlighted = i
                self?.commitHighlight()
            }
            // Add to the stack BEFORE relating row.width to stack.width — the cross-view constraint
            // needs a common ancestor, and activating it first throws (aborting the whole list build).
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

        let card = NSView()
        card.wantsLayer = true
        card.layer?.cornerRadius = 8
        card.layer?.backgroundColor = chrome.background.nsColor.cgColor
        card.layer?.borderWidth = 1
        card.layer?.borderColor = FloatShadow.edge.cgColor
        // Frame-driven: positioned AND sized by frame in positionList (the KeybindHintBubble
        // pattern). An unconstrained origin under `false` can be dropped on a layout pass, so the
        // card owns its own frame rather than relying on width/height constraints.
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
        refreshListHighlight()
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

    private func refreshListHighlight() {
        let chrome = Theme.current.chrome
        for row in rowViews { row.setHighlighted(row.index == highlighted, chrome: chrome) }
    }

    private static func groupHeaderView(_ text: String, chrome: ChromeTheme) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = chrome.ink(alpha: 0.4)
        label.translatesAutoresizingMaskIntoConstraints = false
        let host = NSView()
        host.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: host.centerYAnchor),
            host.heightAnchor.constraint(equalToConstant: Self.headerHeight),
        ])
        return host
    }
}

/// One selectable row in the open list: a leading title, an optional trailing note, and a check
/// when it's the current selection. Highlight fill is driven by `Dropdown.refreshListHighlight()`.
private final class DropdownRowView: NSView {
    let index: Int
    private let onSelect: (Int) -> Void

    init(index: Int, item: DropdownItem, chrome: ChromeTheme, onSelect: @escaping (Int) -> Void) {
        self.index = index
        self.onSelect = onSelect
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 5
        translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: item.title)
        title.font = .systemFont(ofSize: 13)
        title.textColor = chrome.foreground.nsColor
        title.lineBreakMode = .byTruncatingTail
        title.translatesAutoresizingMaskIntoConstraints = false
        addSubview(title)
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        var trailing: [NSView] = []
        if let note = item.note {
            let noteLabel = NSTextField(labelWithString: note)
            noteLabel.font = .systemFont(ofSize: 11)
            noteLabel.textColor = chrome.ink(alpha: 0.4)
            trailing.append(noteLabel)
        }
        if item.isSelected {
            let check = NSImageView()
            check.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)
            check.symbolConfiguration = .init(pointSize: 11, weight: .semibold)
            check.contentTintColor = chrome.accent.nsColor
            trailing.append(check)
        }
        if trailing.isEmpty {
            title.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8).isActive = true
        } else {
            let group = NSStackView(views: trailing)
            group.orientation = .horizontal
            group.spacing = 6
            group.translatesAutoresizingMaskIntoConstraints = false
            addSubview(group)
            NSLayoutConstraint.activate([
                group.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 8),
                group.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
                group.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func mouseDown(with event: NSEvent) { onSelect(index) }

    func setHighlighted(_ isHighlighted: Bool, chrome: ChromeTheme) {
        layer?.backgroundColor = (isHighlighted ? chrome.ink(alpha: 0.10) : NSColor.clear).cgColor
    }
}
