import AppKit

struct CheckboxDropdownItem: Equatable {
    let title: String
    let isChecked: Bool
    /// A muted trailing word, for what the title alone does not say (how many files a folded
    /// folder stands in for). Nil on an ordinary row.
    let note: String?
    /// An SF Symbol shown before the title, where the rows are of more than one kind.
    let symbol: String?

    init(title: String, isChecked: Bool, note: String? = nil, symbol: String? = nil) {
        self.title = title
        self.isChecked = isChecked
        self.note = note
        self.symbol = symbol
    }
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
    /// Fired once when the open list closes, then cleared. An owner that needs to rebuild the
    /// control waits on this rather than pulling the card out from under a multi-select in progress.
    var onClosed: (() -> Void)?

    /// The closed-state title. The query displaces it in the same label while one is being typed.
    private var summary: String
    private let titleLabel = NSTextField(labelWithString: "")
    /// Retained (not a throwaway init-local) so `reapplyTheme()` can re-tint it on a theme swap.
    private let chevron = NSImageView()
    /// The floating list. Built lazily because it holds an `unowned` reference back to this view,
    /// and because the self-close hook it carries reaches back through `self` too.
    private lazy var popover: ListPopover = {
        let popover = ListPopover(anchor: self)
        // A window resize closes the list on its own; drop the lit border and the stale rows with it.
        // A window resize closes the card without going through `closeList`, so everything that
        // hangs off a close has to be done here too: a stranded `onClosed` never fires again.
        popover.onSelfClose = { [weak self] in
            self?.rowViews = []
            self?.query = ""
            self?.renderTitle()
            self?.restyle()
            self?.fireClosed()
        }
        return popover
    }()
    private var rowViews: [CheckboxRowView] = []
    /// The item indices the query admits, in ranked order. The rows the card holds, one per entry.
    private var visible: [Int] = []
    /// Type-to-filter, live only while the list is open. A carry list is as long as the repo's
    /// `.gitignore`, which is past what arrowing can reach.
    private var query = ""
    /// An index into `items`, not into `visible`.
    private var highlighted = 0
    /// The rows shown while nothing is typed. A query searches every item, so a row left out of
    /// this is reachable by name but not by scrolling: the copy list folds a noisy folder into one
    /// row at rest and still lets you pick a single file out of it.
    var restingIndices: [Int]?
    private var isFocusedStop = false

    private static let rowHeight: CGFloat = 28

    // MARK: test hooks

    var buttonTitleForTesting: String { titleLabel.stringValue }
    var itemsForTesting: [CheckboxDropdownItem] { items }
    var isPopoverOpen: Bool { popover.isOpen }
    var highlightedIndexForTesting: Int { highlighted }
    var queryForTesting: String { query }
    var visibleIndicesForTesting: [Int] { visible }
    /// The open list's row views in list order, for click tests that drive a row's real `mouseDown`.
    var rowViewsForTesting: [NSView] { rowViews }
    func openListForTesting() { openList() }
    var listCardSizeForTesting: NSSize { popover.cardFrame.size }

    init(title: String, items: [CheckboxDropdownItem], onToggle: @escaping (Int) -> Void) {
        self.items = items
        self.rowCount = items.count
        self.onToggle = onToggle
        self.summary = title
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 6
        PopoverButtonStyle.applyRestFill(to: self)
        layer?.borderWidth = 1
        layer?.borderColor = Theme.current.chrome.fill(alpha: ChromeTheme.border).cgColor

        titleLabel.font = .systemFont(ofSize: 13)
        titleLabel.textColor = Theme.current.chrome.foreground.nsColor
        titleLabel.stringValue = title
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.lineBreakMode = .byTruncatingTail

        chevron.image = NSImage(systemSymbolName: "chevron.up.chevron.down", accessibilityDescription: nil)
        chevron.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
        chevron.contentTintColor = Theme.current.chrome.ink(.muted)
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
        summary = title
        renderTitle()
        refreshRows()
    }

    /// Re-apply the live chrome colors after a config change — no relaunch. The open list is
    /// rebuilt fresh (reading `Theme.current`) on every open, so only the button needs recoloring.
    func reapplyTheme() {
        restyle()
        renderTitle()
        chevron.contentTintColor = Theme.current.chrome.ink(.muted)
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
            case .escape: escapePressed()
            case .delete: backspace()
            default: typed(event)  // consume every other key while the list is open
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
        // Guarded before `buildRows()`, which reassigns `rowViews`: a second open would leave those
        // pointing at fresh views that are in no card, so the mounted rows stop repainting.
        guard !popover.isOpen, window?.contentView != nil else { return }
        query = ""
        refilter()
        highlighted = visible.first ?? 0
        popover.open(rows: buildRows())
        // After the open: `refreshRows` gates the highlight on the list being up, so painting
        // before it would leave the first row unhighlighted until an arrow moves.
        refreshRows()
        restyle()
    }

    private func closeList() {
        let wasOpen = popover.isOpen
        popover.close()
        rowViews = []
        query = ""
        renderTitle()
        restyle()
        guard wasOpen else { return }
        fireClosed()
    }

    private func fireClosed() {
        guard let closed = onClosed else { return }
        onClosed = nil
        closed()
    }

    /// Esc clears a mistyped query before it closes anything, so recovering does not mean
    /// reopening. Mirrors `Dropdown`.
    private func escapePressed() {
        guard !query.isEmpty else { return closeList() }
        query = ""
        rerenderList()
    }

    private func backspace() {
        guard !query.isEmpty else { return }
        query.removeLast()
        rerenderList()
    }

    /// A printable key filters. **Space is not one:** it toggles, the way a checkbox list should,
    /// and a fuzzy query over paths has no use for one. That is the one deliberate divergence from
    /// `Dropdown`, which owns Space because it commits on Return instead.
    private func typed(_ event: NSEvent) {
        // Home, End, the page keys and every F-key decode to no focus key and arrive here carrying
        // a private-use scalar, which is printable as far as `Character` is concerned: unfiltered
        // they entered the query, emptied the list and rendered the button as tofu.
        guard event.modifierFlags.isDisjoint(with: [.command, .control, .option]),
            let characters = event.charactersIgnoringModifiers, !characters.isEmpty,
            characters.unicodeScalars.allSatisfy(Self.isTypable)
        else { return }
        query += characters
        rerenderList()
    }

    /// Whether a scalar belongs in a query: not whitespace, not a control code, and outside the
    /// private-use block AppKit encodes the non-printing keys in.
    private static func isTypable(_ scalar: Unicode.Scalar) -> Bool {
        !CharacterSet.whitespacesAndNewlines.contains(scalar)
            && !CharacterSet.controlCharacters.contains(scalar)
            && !(0xF700...0xF8FF).contains(scalar.value)
    }

    /// Recompute `visible` from `query`, ranked by the scorer the command palette uses, so "cred"
    /// finds `config/credentials/development.key`.
    private func refilter() {
        guard !query.isEmpty else {
            visible = restingIndices.map { $0.filter(items.indices.contains) } ?? Array(items.indices)
            return
        }
        visible =
            items.indices
            .compactMap { index -> (index: Int, score: Int)? in
                guard let score = FuzzyMatch.score(query, items[index].title) else { return nil }
                return (index, score)
            }
            // Stable on ties so equally-scored rows keep catalog order rather than shuffling.
            .sorted { $0.score == $1.score ? $0.index < $1.index : $0.score > $1.score }
            .map(\.index)
    }

    /// Re-render the open card after the query moved. `ListPopover.open` no-ops while one is up,
    /// so it comes down first; the query and highlight live here, not in the card.
    private func rerenderList() {
        renderTitle()
        guard popover.isOpen else { return }
        let before = visible
        refilter()
        guard visible != before else { return }
        // Back to the top match on every query change, unlike `Dropdown`, whose highlight starts on
        // the current selection. This one starts on row 0, so keeping it would let Return commit a
        // lower-ranked row than the one the query just promoted.
        highlighted = visible.first ?? highlighted
        popover.close()
        popover.open(rows: buildRows())
        refreshRows()
    }

    private func renderTitle() {
        titleLabel.stringValue = query.isEmpty ? summary : query
        titleLabel.textColor =
            query.isEmpty ? Theme.current.chrome.foreground.nsColor : Theme.current.chrome.accent.nsColor
    }

    private func moveHighlight(_ delta: Int) {
        let at = visible.firstIndex(of: highlighted)
        guard let next = KeyboardFocus.step(from: at, delta: delta, count: visible.count) else { return }
        highlighted = visible[next]
        refreshRows()
        guard rowViews.indices.contains(next) else { return }
        let row = rowViews[next]
        row.scrollToVisible(row.bounds)
    }

    /// A row the query filtered out is not committable: the highlight survives a query that admits
    /// nothing, and toggling it would change an entry the user cannot see.
    private func toggleHighlight() {
        guard visible.contains(highlighted) else { return }
        toggle(highlighted)
    }

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
        for (row, index) in zip(rowViews, visible) {
            guard items.indices.contains(index) else { continue }
            row.render(
                item: items[index], isHighlighted: popover.isOpen && index == highlighted,
                chrome: chrome)
        }
    }

    /// One row per item the query admits; `ListPopover` sizes them and assembles the card. A query
    /// that admits nothing gets a line saying so, or the card renders as an empty sliver.
    private func buildRows() -> [ListPopover.Row] {
        rowViews = []
        guard !visible.isEmpty else {
            return [ListPopover.Row(view: Self.emptyRowView(), height: Self.rowHeight)]
        }
        return visible.map { index in
            let row = CheckboxRowView { [weak self] in self?.toggle(index) }
            rowViews.append(row)
            return ListPopover.Row(view: row, height: Self.rowHeight)
        }
    }

    private static func emptyRowView() -> NSView {
        let label = NSTextField(labelWithString: "No matches")
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = Theme.current.chrome.ink(.muted)
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

    /// One checkbox row in the open list: a fixed-width check slot (titles align whether checked
    /// or not) and the title. Checked rows show an accent check and full-strength title; unchecked
    /// rows dim the title. The keyboard highlight fills like a `Dropdown` row.
    private final class CheckboxRowView: NSView {
        private let onClick: () -> Void
        private let check = NSImageView()
        private let title = NSTextField(labelWithString: "")
        private let note = NSTextField(labelWithString: "")
        private let icon = NSImageView()

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
            note.font = .systemFont(ofSize: 11)
            note.translatesAutoresizingMaskIntoConstraints = false
            note.setContentCompressionResistancePriority(.required, for: .horizontal)
            icon.symbolConfiguration = .init(pointSize: 11, weight: .regular)
            icon.translatesAutoresizingMaskIntoConstraints = false
            addSubview(check)
            addSubview(icon)
            addSubview(title)
            addSubview(note)
            NSLayoutConstraint.activate([
                check.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
                check.widthAnchor.constraint(equalToConstant: 14),
                check.centerYAnchor.constraint(equalTo: centerYAnchor),
                icon.leadingAnchor.constraint(equalTo: check.trailingAnchor, constant: 6),
                icon.widthAnchor.constraint(equalToConstant: 14),
                icon.centerYAnchor.constraint(equalTo: centerYAnchor),
                title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
                title.trailingAnchor.constraint(lessThanOrEqualTo: note.leadingAnchor, constant: -8),
                title.centerYAnchor.constraint(equalTo: centerYAnchor),
                note.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
                note.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        func render(item: CheckboxDropdownItem, isHighlighted: Bool, chrome: ChromeTheme) {
            title.stringValue = item.title
            title.textColor = item.isChecked ? chrome.foreground.nsColor : chrome.ink(.muted)
            note.stringValue = item.note ?? ""
            note.textColor = chrome.ink(.faint)
            note.isHidden = item.note == nil
            icon.image = item.symbol.flatMap {
                NSImage(systemSymbolName: $0, accessibilityDescription: nil)
            }
            icon.contentTintColor = item.isChecked ? chrome.accent.nsColor : chrome.ink(.subtle)
            icon.isHidden = item.symbol == nil
            check.isHidden = !item.isChecked
            check.contentTintColor = chrome.accent.nsColor
            layer?.backgroundColor = (isHighlighted ? chrome.fill(.hover) : NSColor.clear).cgColor
        }

        override func mouseDown(with event: NSEvent) { onClick() }
    }
}
