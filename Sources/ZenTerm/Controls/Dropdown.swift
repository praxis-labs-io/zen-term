import AppKit

/// One row in a `Dropdown` menu: a title, an optional group header shown above it, an optional
/// trailing note (e.g. "Light"/"Dark"), and whether it's the current selection (drawn with a check).
///
/// `swatch` fills a leading dot for rows whose subject *is* a color (the accent picker) — a name
/// like "Magenta" is a conventional ANSI label, not a claim about the theme's actual hue, so the
/// dot is what makes the row honest. Nil for every other picker, which renders exactly as before.
struct DropdownItem: Equatable {
    let title: String
    let group: String?
    let note: String?
    let isSelected: Bool
    let swatch: NSColor?

    init(title: String, group: String?, note: String?, isSelected: Bool, swatch: NSColor? = nil) {
        self.title = title
        self.group = group
        self.note = note
        self.isSelected = isSelected
        self.swatch = swatch
    }
}

/// A keyboard-navigable themed dropdown: a compact button showing the current item; Return/Space/
/// click opens a floating list of rows (grouped headers, trailing notes, a check on the active one).
/// Up/Down move the highlight, Return selects, Esc closes the list. As a form focus stop it bubbles
/// Up/Down at the list's closed state to the section (like `SegmentedControl`). Styling mirrors
/// `FieldBox`.
final class Dropdown: NSView {
    private(set) var selectedIndex: Int
    private var items: [DropdownItem]
    private let onChange: (Int) -> Void

    var onArrowUp: (() -> Void)?
    var onArrowDown: (() -> Void)?
    var onArrowLeft: (() -> Void)?
    var onTab: (() -> Void)?
    var onBacktab: (() -> Void)?

    private let titleLabel = NSTextField(labelWithString: "")
    /// Retained (not a throwaway init-local) so `reapplyTheme()` can re-tint it on a theme swap.
    private let chevron = NSImageView()
    /// The selected item's color dot, hidden unless the item carries a swatch. Its fill comes from
    /// the item, not from `Theme.current`, so `reapplyTheme()` leaves it alone — the owning section
    /// re-supplies items on a theme change and `renderTitle()` repaints it from those.
    private let swatch = NSView()
    private var titleAfterSwatch = NSLayoutConstraint()
    private var titleAtLeading = NSLayoutConstraint()
    /// The floating list. Built lazily because it holds an `unowned` reference back to this view,
    /// and because the self-close hook it carries reaches back through `self` too.
    private lazy var popover: ListPopover = {
        let popover = ListPopover(anchor: self)
        // A window resize closes the list on its own; drop the lit border and the stale rows with it.
        popover.onSelfClose = { [weak self] in
            self?.rowViews = []
            self?.restyle()
        }
        return popover
    }()
    private var rowViews: [DropdownRowView] = []
    private var highlighted = 0
    private var isFocusedStop = false

    static let swatchSize: CGFloat = 10
    private static let rowHeight: CGFloat = 28
    private static let headerHeight: CGFloat = 20

    /// Test hook: the button's current title.
    var buttonTitleForTesting: String { titleLabel.stringValue }
    /// Test hook: the rows as supplied by the owning section, so a picker can assert what it built
    /// (swatches, notes, grouping) without opening the list.
    var itemsForTesting: [DropdownItem] { items }

    /// Test hooks: open the floating list and inspect it (there is no other public list API). The
    /// list open-path has no GUI test seam otherwise, and shipped once rendering at zero size.
    func openListForTesting() { openList() }
    var listCardSizeForTesting: NSSize { popover.cardFrame.size }
    /// Test hook: where the card landed in window coordinates. Size alone can't tell a card placed
    /// below the button from one that ran off the bottom of the window.
    var listCardFrameForTesting: NSRect { popover.cardFrame }
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
        PopoverButtonStyle.applyRestFill(to: self)
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

        swatch.wantsLayer = true
        swatch.layer?.cornerRadius = Self.swatchSize / 2
        swatch.layer?.borderWidth = 1
        swatch.layer?.borderColor = Theme.current.chrome.ink(alpha: 0.15).cgColor
        swatch.isHidden = true
        swatch.translatesAutoresizingMaskIntoConstraints = false

        addSubview(swatch)
        addSubview(titleLabel)
        addSubview(chevron)
        titleAfterSwatch = titleLabel.leadingAnchor.constraint(
            equalTo: swatch.trailingAnchor, constant: 7)
        titleAtLeading = titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 30),
            swatch.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            swatch.centerYAnchor.constraint(equalTo: centerYAnchor),
            swatch.widthAnchor.constraint(equalToConstant: Self.swatchSize),
            swatch.heightAnchor.constraint(equalToConstant: Self.swatchSize),
            titleAtLeading,
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

    /// An optional lead shown before the selected item in the button only (not the list rows), e.g.
    /// `"Base: "` so the button reads `Base: main` while the rows stay bare branch names. Empty by
    /// default, so existing dropdowns are unchanged.
    var titlePrefix: String = "" { didSet { renderTitle() } }

    /// Let the title yield and truncate rather than holding the control open at its natural width.
    ///
    /// Off by default, because most dropdowns sit in containers sized around them and a truncated
    /// theme name would be a regression there. The diff viewer's branch pickers turn it on: they hold
    /// branch names, which are unbounded, and the width of the column they sit in is the file tree's
    /// to decide, not theirs. Same rule as the viewer's footer labels, and it has to be the
    /// label that yields, not just its container, or the intrinsic width still holds the column open.
    var titleTruncatesUnderPressure: Bool = false {
        didSet {
            let priority: NSLayoutConstraint.Priority = titleTruncatesUnderPressure ? .defaultLow : .defaultHigh
            titleLabel.setContentCompressionResistancePriority(priority, for: .horizontal)
            setContentCompressionResistancePriority(priority, for: .horizontal)
        }
    }

    private func renderTitle() {
        let item = items.indices.contains(selectedIndex) ? items[selectedIndex] : nil
        titleLabel.stringValue = item.map { titlePrefix + $0.title } ?? ""
        // Swap which constraint holds the title rather than reflowing: the dot only exists for
        // color pickers, and every other dropdown must keep its exact leading inset.
        swatch.layer?.backgroundColor = item?.swatch?.cgColor
        swatch.isHidden = item?.swatch == nil
        titleAfterSwatch.isActive = false
        titleAtLeading.isActive = false
        (swatch.isHidden ? titleAtLeading : titleAfterSwatch).isActive = true
    }

    /// Re-apply the live chrome colors after a config change — no relaunch. `restyle()` already
    /// reads `Theme.current` fresh, but doesn't touch the title/chevron (set once in init); the
    /// open list popover needs nothing here since it's rebuilt fresh (reading Theme fresh) on
    /// every open.
    func reapplyTheme() {
        restyle()
        titleLabel.textColor = Theme.current.chrome.foreground.nsColor
        chevron.contentTintColor = Theme.current.chrome.ink(alpha: 0.5)
        swatch.layer?.borderColor = Theme.current.chrome.ink(alpha: 0.15).cgColor
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

    /// The open list card is parented to the window's content view (so it escapes the dropdown's
    /// own bounds), not to the dropdown's subtree — so removing the dropdown, or an ancestor like
    /// the Settings modal, doesn't take the card with it. Closing it when the dropdown leaves the
    /// window binds the card's lifetime to the control: a tab-switch `closeModal()` that tears out
    /// the host can no longer strand a dead list on the content view, stuck over every tab.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { closeList() }
    }

    private func restyle() {
        PopoverButtonStyle.apply(to: self, isFocused: isFocusedStop, isOpen: popover.isOpen)
    }

    // MARK: keyboard

    override func keyDown(with event: NSEvent) {
        if popover.isOpen {
            switch KeyboardFocus.key(for: event) {
            case .up: moveHighlight(-1)
            case .down: moveHighlight(1)
            case .activate: commitHighlight()  // return / enter / space
            // This local Esc is what makes layered dismissal work: a bare Esc reaches the focused
            // control's keyDown before any card-root performKeyEquivalent, so closing the list here
            // keeps the card open. Don't hoist Esc to the card root — that's the dead-end.
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

    /// Test hook: whether the floating list is open right now.
    var isPopoverOpen: Bool { popover.isOpen }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        popover.isOpen ? closeList() : openList()
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
        // Guarded before `buildRows()`, which reassigns `rowViews`: a second open would leave those
        // pointing at fresh views that are in no card, so the mounted rows stop repainting and the
        // arrow keys move a highlight nobody can see.
        guard !popover.isOpen, window?.contentView != nil else { return }
        highlighted = selectedIndex
        popover.open(rows: buildRows())
        refreshListHighlight()
        scrollHighlightIntoView()  // open scrolled to the current selection when it's below the fold
        restyle()
    }

    private func closeList() {
        popover.close()
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

    /// The list's contents, in order: a faint group header wherever the group changes, then the
    /// rows. `ListPopover` sizes each line and assembles the card around them; a row draws an
    /// optional leading swatch, the title, a trailing note, and a check when it is the selection.
    private func buildRows() -> [ListPopover.Row] {
        let chrome = Theme.current.chrome
        rowViews = []
        var lines: [ListPopover.Row] = []
        var previousGroup: String?
        for (index, item) in items.enumerated() {
            if let group = item.group, group != previousGroup {
                lines.append(
                    ListPopover.Row(
                        view: Self.groupHeaderView(group, chrome: chrome), height: Self.headerHeight))
            }
            previousGroup = item.group
            let row = DropdownRowView(index: index, item: item, chrome: chrome) { [weak self] i in
                self?.highlighted = i
                self?.commitHighlight()
            }
            rowViews.append(row)
            lines.append(ListPopover.Row(view: row, height: Self.rowHeight))
        }
        return lines
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
        ])
        return host
    }
}

/// One selectable row in the open list: an optional leading color dot, a title, an optional
/// trailing note, and a check when it's the current selection. Highlight fill is driven by
/// `Dropdown.refreshListHighlight()`.
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
        NSLayoutConstraint.activate([title.centerYAnchor.constraint(equalTo: centerYAnchor)])
        if let swatchColor = item.swatch {
            let dot = NSView()
            dot.wantsLayer = true
            dot.layer?.cornerRadius = Dropdown.swatchSize / 2
            dot.layer?.backgroundColor = swatchColor.cgColor
            // A dark theme's black slot would vanish against the list card, so ring every dot.
            dot.layer?.borderWidth = 1
            dot.layer?.borderColor = chrome.ink(alpha: 0.15).cgColor
            dot.translatesAutoresizingMaskIntoConstraints = false
            addSubview(dot)
            NSLayoutConstraint.activate([
                dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
                dot.centerYAnchor.constraint(equalTo: centerYAnchor),
                dot.widthAnchor.constraint(equalToConstant: Dropdown.swatchSize),
                dot.heightAnchor.constraint(equalToConstant: Dropdown.swatchSize),
                title.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 7),
            ])
        } else {
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8).isActive = true
        }

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
