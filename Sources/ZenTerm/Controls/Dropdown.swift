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
        // A window resize closes the list on its own. Tear down the same way an Esc does: the field
        // has to be handed back too, or the button is left looking like an empty search box holding a
        // query that typing can no longer change, because `rerenderList` bails on a closed list.
        popover.onSelfClose = { [weak self] in
            self?.query = ""
            self?.endEditing()
            self?.rowViews = []
            self?.restyle()
        }
        return popover
    }()
    private var rowViews: [DropdownRowView] = []
    private var highlighted = 0
    /// Type-to-filter query, live only while the list is open. Sixty-five themes is past what
    /// arrowing can manage, and the same list is the accent picker and every other long row.
    private let queryField = NSTextField()
    /// True while the button is showing its field, so `resignFirstResponder` can tell a hand-off to
    /// that field from focus genuinely leaving the control.
    private var isEditing = false
    private var query = ""
    /// Original `items` indices the query admits, in the order they are shown. `highlighted` and
    /// `DropdownRowView.index` stay original indices throughout, so `onChange` reports the item the
    /// user picked rather than the position it happened to occupy while filtered.
    private var visible: [Int] = []
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

        // The button becomes the search input while the list is open: a combo box, so the thing you
        // clicked is the thing you type into. Borderless and laid over the title, matching
        // `PaletteOverlay`'s search row rather than introducing a second look for the same job.
        queryField.font = .systemFont(ofSize: 13)
        queryField.textColor = Theme.current.chrome.foreground.nsColor
        queryField.isBordered = false
        queryField.drawsBackground = false
        queryField.focusRingType = .none
        queryField.isHidden = true
        queryField.delegate = self
        queryField.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: 13)
        titleLabel.textColor = Theme.current.chrome.foreground.nsColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.lineBreakMode = .byTruncatingTail

        chevron.image = NSImage(systemSymbolName: "chevron.up.chevron.down", accessibilityDescription: nil)
        chevron.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
        chevron.contentTintColor = Theme.current.chrome.ink(.muted)
        chevron.translatesAutoresizingMaskIntoConstraints = false

        swatch.wantsLayer = true
        swatch.layer?.cornerRadius = Self.swatchSize / 2
        swatch.layer?.borderWidth = 1
        swatch.layer?.borderColor = Theme.current.chrome.ink(alpha: 0.15).cgColor
        swatch.isHidden = true
        swatch.translatesAutoresizingMaskIntoConstraints = false

        addSubview(swatch)
        addSubview(titleLabel)
        addSubview(queryField)
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
            queryField.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            queryField.centerYAnchor.constraint(equalTo: centerYAnchor),
            queryField.trailingAnchor.constraint(equalTo: chevron.leadingAnchor, constant: -6),
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
    /// theme name would be a regression there. Turn it on for a dropdown holding an unbounded
    /// value in a column something else sizes. It has to be the label that yields, not just its
    /// container, or the intrinsic width still holds the column open.
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
    /// reads `Theme.current` fresh, but doesn't touch the title/chevron (set once in init).
    ///
    /// **The open list is rebuilt too.** Its rows bake in the theme at build time, and it used to be
    /// true that a theme could not change while one was up. `⌘⇧,` reloads the config with a list
    /// open, which left the card painted in the previous theme: a dark popover hanging under a light
    /// Settings card.
    func reapplyTheme() {
        restyle()
        titleLabel.textColor = Theme.current.chrome.foreground.nsColor
        chevron.contentTintColor = Theme.current.chrome.ink(.muted)
        swatch.layer?.borderColor = Theme.current.chrome.ink(alpha: 0.15).cgColor
        // The field outlives a theme change while the list is open, so its text and placeholder go
        // stale in the old theme's foreground otherwise.
        queryField.textColor = Theme.current.chrome.foreground.nsColor
        if !queryField.isHidden {
            renderQueryPlaceholder()
            queryField.applyThemedCaret()
        }
        rebuildOpenList()
    }

    // MARK: focus

    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool {
        isFocusedStop = true
        restyle()
        return true
    }
    /// Losing focus closes the list, which is what makes clicking away dismiss it. Handing focus to
    /// this control's *own* field is not losing it: the combo box does exactly that on open, and
    /// closing there would shut the list in the same breath as opening it. The click-away case while
    /// editing is caught by `controlTextDidEndEditing` instead.
    override func resignFirstResponder() -> Bool {
        isFocusedStop = false
        if !isEditing { closeList() }
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

    /// **The open branch is a fallback, not the normal path.** Opening hands first responder to the
    /// query field, so a real keystroke reaches the field editor and
    /// `control(_:textView:doCommandBy:)` routes it. This still runs when `makeFirstResponder` was
    /// refused, which leaves the list open with the button holding focus. Drive it from a test only
    /// to cover that case — asserting the list's keys through here proves nothing about the keys a
    /// user presses.
    override func keyDown(with event: NSEvent) {
        if popover.isOpen {
            switch KeyboardFocus.key(for: event) {
            case .up: moveHighlight(-1)
            case .down: moveHighlight(1)
            case .activate: commitHighlight()  // return / enter / space
            // This local Esc is what makes layered dismissal work: a bare Esc reaches the focused
            // control's keyDown before any card-root performKeyEquivalent, so closing the list here
            // keeps the card open. Don't hoist Esc to the card root — that's the dead-end.
            case .escape: escapePressed()
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

    /// Esc clears a mistyped filter before it closes anything, so recovering does not mean reopening.
    private func escapePressed() {
        if query.isEmpty {
            closeList()
        } else {
            query = ""
            queryField.stringValue = ""
            rerenderList()
        }
    }

    /// Test hook: type into the combo box's field the way a person does, through the delegate the
    /// field really calls, so a test cannot pass against a query the field never received.
    func typeForTesting(_ text: String) {
        queryField.stringValue = text
        controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: queryField))
    }

    /// Test hook: whether the button is showing its field rather than its static title.
    var isEditingForTesting: Bool { !queryField.isHidden }

    /// Test hook: route a field-editor command the way the real field editor does.
    func fieldCommandForTesting(_ selector: Selector) -> Bool {
        control(queryField, textView: NSTextView(), doCommandBy: selector)
    }

    /// Test hook: the colour the field's own text is painted in, so a theme swap is assertable.
    var queryFieldTextColorForTesting: NSColor? { queryField.textColor }

    /// Test hook: the colour each mounted row is painted in, so a stale card is assertable.
    var rowFillsForTesting: [NSColor?] {
        rowViews.map { $0.layer?.backgroundColor.flatMap(NSColor.init(cgColor:)) }
    }

    /// Test hook: the live filter query.
    var queryForTesting: String { query }

    /// Test hook: the item indices the query admits, in shown order.
    var visibleIndicesForTesting: [Int] { visible }

    /// Test hook: whether the floating list is open right now.
    var isPopoverOpen: Bool { popover.isOpen }

    /// Read `isOpen` **before** touching first responder. Taking focus ends the query field's editing
    /// session, which closes the list synchronously through `controlTextDidEndEditing`, so a ternary
    /// tested afterwards always sees a closed list and reopens the one it just shut. That took
    /// click-to-dismiss off every dropdown in Settings.
    override func mouseDown(with event: NSEvent) {
        let wasOpen = popover.isOpen
        window?.makeFirstResponder(self)
        if wasOpen { closeList() } else { openList() }
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
        query = ""
        refilter()
        highlighted = selectedIndex
        beginEditing()
        popover.open(rows: buildRows())
        refreshListHighlight()
        scrollHighlightIntoView()  // open scrolled to the current selection when it's below the fold
        restyle()
    }

    private func closeList() {
        popover.close()
        query = ""
        endEditing()
        rowViews = []
        restyle()
    }

    /// Hand the button over to the field: the placeholder keeps the current selection readable while
    /// the field is empty, so the row never looks blanked out.
    private func beginEditing() {
        queryField.stringValue = ""
        renderQueryPlaceholder()
        titleLabel.isHidden = true
        queryField.isHidden = false
        isEditing = true
        window?.makeFirstResponder(queryField)
        queryField.applyThemedCaret()  // the field editor exists only once the field has focus
    }

    /// Focus returns to the dropdown so arrowing and tabbing continue from here.
    ///
    /// **Restored before the field is hidden, and gated on `isEditing` rather than on who holds
    /// focus now.** Hiding a view that holds first responder makes AppKit dump focus to the window,
    /// so a check afterwards reads false and the restore never runs: Esc closed the list and left
    /// focus nowhere, with no arrow key reaching anything.
    private func endEditing() {
        let wasEditing = isEditing
        isEditing = false
        if wasEditing { window?.makeFirstResponder(self) }
        queryField.isHidden = true
        titleLabel.isHidden = false
    }

    /// AppKit's `placeholderString` draws in `placeholderTextColor`, which follows
    /// `effectiveAppearance` rather than `Theme.current`. Build it attributed, from the chrome ink.
    private func renderQueryPlaceholder() {
        let title = items.indices.contains(selectedIndex) ? items[selectedIndex].title : ""
        queryField.placeholderAttributedString = NSAttributedString(
            string: title,
            attributes: [
                .foregroundColor: Theme.current.chrome.ink(.muted),
                .font: NSFont.systemFont(ofSize: 13),
            ])
    }

    private func moveHighlight(_ delta: Int) {
        guard let position = visible.firstIndex(of: highlighted),
            let nextPosition = KeyboardFocus.step(from: position, delta: delta, count: visible.count)
        else { return }
        highlighted = visible[nextPosition]
        refreshListHighlight()
        scrollHighlightIntoView()
    }

    /// Keep the highlighted row visible as arrow keys move it past the scroll view's capped height.
    private func scrollHighlightIntoView() {
        guard let row = rowViews.first(where: { $0.index == highlighted }) else { return }
        row.scrollToVisible(row.bounds)
    }

    private func commitHighlight() {
        guard visible.contains(highlighted) else { return }  // committing a filtered-out row picks nothing
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
    /// Recompute `visible` from `query`. An empty query admits everything in catalog order; a query
    /// ranks by `FuzzyMatch`, the same scorer the command palette uses, so "gvl" finds Gruvbox Light.
    private func refilter() {
        guard !query.isEmpty else {
            visible = Array(items.indices)
            return
        }
        visible =
            items.indices
            .compactMap { index -> (index: Int, score: Int)? in
                guard let score = FuzzyMatch.score(query, items[index].title) else { return nil }
                return (index, score)
            }
            // Stable on ties so equally-scored rows keep catalog order rather than shuffling per keystroke.
            .sorted { $0.score == $1.score ? $0.index < $1.index : $0.score > $1.score }
            .map(\.index)
    }

    /// Rebuild the open card from scratch. `ListPopover.open` no-ops while one is up, so it comes
    /// down first. Query and highlight survive because they live here, not in the card.
    private func rebuildOpenList() {
        guard popover.isOpen else { return }
        popover.close()
        popover.open(rows: buildRows())
        refreshListHighlight()
        scrollHighlightIntoView()
    }

    /// Re-render the open list after the query moved.
    private func rerenderList() {
        guard popover.isOpen else { return }
        let before = visible
        refilter()
        // Rebuilding the card costs about 22 ms at sixty-five rows and 3 ms at six, so skip it when
        // the query narrowed nothing: typing on past a unique match is the common way to hit this.
        guard visible != before else { return }
        if !visible.contains(highlighted) { highlighted = visible.first ?? highlighted }
        rebuildOpenList()
    }

    private func buildRows() -> [ListPopover.Row] {
        let chrome = Theme.current.chrome
        rowViews = []
        var lines: [ListPopover.Row] = []
        var previousGroup: String?
        if visible.isEmpty {
            lines.append(
                ListPopover.Row(
                    view: Self.groupHeaderView("No matches", chrome: chrome), height: Self.headerHeight))
            return lines
        }
        for index in visible {
            let item = items[index]
            if query.isEmpty, let group = item.group, group != previousGroup {
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
        label.textColor = chrome.ink(.muted)
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
            noteLabel.textColor = chrome.ink(.muted)
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

/// The field owns text while the list is open, so the list's own keys have to be taken back from
/// the field editor: an `NSTextView` swallows arrows and Return, and Esc would otherwise cancel the
/// field rather than the filter.
extension Dropdown: NSTextFieldDelegate {
    /// Focus leaving the field while the list is open is the click-away case, which `Dropdown`'s own
    /// `resignFirstResponder` no longer sees now that it ignores the hand-off.
    func controlTextDidEndEditing(_ obj: Notification) {
        guard isEditing, window?.firstResponder !== self else { return }
        closeList()
    }

    func controlTextDidChange(_ obj: Notification) {
        query = queryField.stringValue
        rerenderList()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveUp(_:)): moveHighlight(-1)
        case #selector(NSResponder.moveDown(_:)): moveHighlight(1)
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertLineBreak(_:)):
            commitHighlight()
        case #selector(NSResponder.cancelOperation(_:)): escapePressed()
        // Taken back from the field editor for the same reason arrows are. Left to AppKit,
        // `selectNextKeyView` ends editing (closing the list, which hands focus back) and then
        // overwrites that with its own choice — and no form in this app builds a `nextKeyView`
        // chain, so focus landed on the hidden field and the keyboard went dead until a click.
        case #selector(NSResponder.insertTab(_:)):
            closeList()
            onTab?()
        case #selector(NSResponder.insertBacktab(_:)):
            closeList()
            onBacktab?()
        default: return false
        }
        return true
    }
}
