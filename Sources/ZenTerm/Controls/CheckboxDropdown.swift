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
    private var rowViews: [CheckboxRowView] = []
    private var highlighted = 0
    private var isFocusedStop = false

    private static let rowHeight: CGFloat = 28

    // MARK: test hooks

    var buttonTitleForTesting: String { titleLabel.stringValue }
    var itemsForTesting: [CheckboxDropdownItem] { items }
    var isPopoverOpen: Bool { popover.isOpen }
    var highlightedIndexForTesting: Int { highlighted }
    /// The open list's row views in list order, for click tests that drive a row's real `mouseDown`.
    var rowViewsForTesting: [NSView] { rowViews }
    func openListForTesting() { openList() }
    var listCardSizeForTesting: NSSize { popover.cardFrame.size }

    init(title: String, items: [CheckboxDropdownItem], onToggle: @escaping (Int) -> Void) {
        self.items = items
        self.rowCount = items.count
        self.onToggle = onToggle
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 6
        PopoverButtonStyle.applyRestFill(to: self)
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
        PopoverButtonStyle.apply(to: self, isFocused: isFocusedStop, isOpen: popover.isOpen)
    }

    // MARK: keyboard

    override func keyDown(with event: NSEvent) {
        if popover.isOpen {
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
        popover.isOpen ? closeList() : openList()
    }

    /// The whole control is one click target — without this the title label and chevron swallow
    /// the click and only the padding gaps would open the list.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, alphaValue > 0 else { return nil }
        return bounds.contains(convert(point, from: superview)) ? self : nil
    }

    // MARK: list

    private func openList() {
        highlighted = 0
        popover.open(rows: buildRows())
        guard popover.isOpen else { return }  // no window to hang it on
        // After the open: `refreshRows` gates the highlight on the list being up, so painting
        // before it would leave the first row unhighlighted until an arrow moves.
        refreshRows()
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
                item: items[index], isHighlighted: popover.isOpen && index == highlighted,
                chrome: chrome)
        }
    }

    /// One row per item; `ListPopover` sizes them and assembles the card around them.
    private func buildRows() -> [ListPopover.Row] {
        rowViews = []
        return items.indices.map { index in
            let row = CheckboxRowView { [weak self] in self?.toggle(index) }
            rowViews.append(row)
            return ListPopover.Row(view: row, height: Self.rowHeight)
        }
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
