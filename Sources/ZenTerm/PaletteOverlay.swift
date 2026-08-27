import AppKit

/// A row inside a palette list. The overlay drives selection highlighting through this.
protocol PaletteRowView: NSView {
    var isSelected: Bool { get set }
    /// Run when the row is clicked. The overlay re-binds this on every (re)load, so a row REUSED at
    /// a new index after a filter activates *that* index rather than the one it was built at.
    var onActivate: (() -> Void)? { get set }
}

/// One footer hint: a key glyph string (rendered as a keycap, same as a row's shortcut)
/// and the action it performs. e.g. `PaletteHint(keys: "⏎", label: "run")`.
struct PaletteHint {
    let keys: String
    let label: String
}

/// A selectable palette row with the shared selection chrome: rounded corners, an iris
/// highlight when selected, and a single click that runs the row (Raycast / Spotlight, not a
/// select-then-double-click). Subclasses add their own content in `init` after calling `super.init`.
class SelectableRowView: NSView, PaletteRowView {
    var onActivate: (() -> Void)?
    var isSelected = false { didSet { updateBackground() } }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // Accept the press so the matching mouseUp lands here, then run the row on release — but only
    // if it lands back inside the row, so a press-and-drag-off cancels like any button.
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onActivate?() }
    }

    private func updateBackground() {
        layer?.backgroundColor = (isSelected ? Theme.current.chrome.selectionFill : .clear).cgColor
    }
}

/// Shared scaffold for the modal command-style overlays over a tab's tile region: a
/// transparent click-catching backdrop, a centered rounded card with a search field, a
/// scrollable keyboard-driven list, and a hint footer. Fully keyboard-driven — arrows
/// move the selection, Enter activates, Esc closes; a backdrop click also dismisses.
///
/// Subclasses supply the model + row content via the template hooks (`numberOfRows`,
/// `makeRow`, `applyFilter`, `activate`); the base owns all the chrome and navigation.
/// `RepoPickerOverlay` (⌘⇧P) and `CommandPaletteOverlay` (⌘P) are the two consumers.
class PaletteOverlay: NSView, ModalOverlay {
    private let onDismiss: () -> Void

    private let card = CardView()
    private var dismiss = DismissGate()
    private let searchGlyph = NSTextField(labelWithString: "⌕")
    private let searchField = NSTextField()
    private let searchPlaceholder: String
    private let divider = NSView()
    /// The same hairline under the footer's top edge, so the hint row reads as its own band the way
    /// the search row does rather than floating over the end of the list.
    private let footerDivider = NSView()
    private let rowsStack = NSStackView()
    private let scrollView = NSScrollView()
    private let emptyLabel: NSTextField
    /// The footer hints' labels + keycaps, retained so `reapplyTheme()` can recolor them — they're
    /// built once in `init` (never rebuilt by a row re-render) and bake their ink color in.
    private var footerHintLabels: [NSTextField] = []
    private var footerKeycaps: [KeycapView] = []
    private let defaultRowHeight: CGFloat
    private let maxListHeight: CGFloat
    private let emptyListHeight: CGFloat
    /// Breathing room between the search divider (and footer) and the row highlights, so a
    /// selected row never touches the search field's bottom border.
    private let listVerticalInset: CGFloat = 8
    private var listHeight: NSLayoutConstraint!
    /// One laid-out row: its reuse identity (nil = never reuse), the view, and the height constraint
    /// the base owns — a reload retunes the constant instead of rebuilding the constraint.
    private struct LaidOutRow {
        let id: AnyHashable?
        let view: PaletteRowView
        let height: NSLayoutConstraint
    }
    private var laidOutRows: [LaidOutRow] = []
    private var selected = 0

    init(
        background: NSColor, placeholder: String, emptyText: String, footerHints: [PaletteHint],
        rowHeight: CGFloat, maxListHeight: CGFloat = 320, emptyListHeight: CGFloat = 56,
        onDismiss: @escaping () -> Void
    ) {
        self.onDismiss = onDismiss
        self.defaultRowHeight = rowHeight
        self.maxListHeight = maxListHeight
        self.emptyListHeight = emptyListHeight
        self.emptyLabel = NSTextField(labelWithString: emptyText)
        self.searchPlaceholder = placeholder
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        // Transparent click-catcher (no dimming) — still dismisses on an outside click.
        let backdrop = BackdropView(onClick: onDismiss)
        backdrop.wantsLayer = true
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        addSubview(backdrop)

        CardChrome.apply(to: card, background: background)
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)

        // Search row: a magnifier glyph + a borderless field.
        searchGlyph.font = .systemFont(ofSize: 16)
        searchGlyph.textColor = Theme.current.chrome.ink(.muted)
        searchField.font = .systemFont(ofSize: 15)
        applyPlaceholder()
        searchField.isBordered = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.textColor = Theme.current.chrome.foreground.nsColor
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false
        let searchRow = NSStackView(views: [searchGlyph, searchField])
        searchRow.orientation = .horizontal
        searchRow.spacing = 8
        searchRow.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)

        for hairline in [divider, footerDivider] {
            hairline.wantsLayer = true
            hairline.layer?.backgroundColor = Theme.current.chrome.fill(alpha: ChromeTheme.hairline).cgColor
            hairline.translatesAutoresizingMaskIntoConstraints = false
            hairline.heightAnchor.constraint(equalToConstant: 1).isActive = true
        }

        // List: a flipped document view (top-down scroll coords) holding a vertical stack.
        rowsStack.orientation = .vertical
        rowsStack.spacing = 0
        rowsStack.alignment = .leading
        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(rowsStack)
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        // Force a slim, auto-hiding overlay bar even when the system is set to always show
        // scroll bars (which would otherwise swap in the wide legacy track once the list
        // overflows — visible on the taller command palette, not the short repo picker).
        scrollView.verticalScroller = SlimScroller()
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.documentView = doc
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.textColor = Theme.current.chrome.ink(.muted)
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.isHidden = true
        scrollView.contentView.addSubview(emptyLabel)

        // The hints get the same keycap treatment as the list rows: each key in a box
        // (SF Symbols where available), its action beside it. Centered in the footer row.
        let (footer, footerLabels, footerKeycaps) = Self.makeFooter(footerHints)
        self.footerHintLabels = footerLabels
        self.footerKeycaps = footerKeycaps
        footer.translatesAutoresizingMaskIntoConstraints = false
        let footerRow = NSView()
        footerRow.translatesAutoresizingMaskIntoConstraints = false
        footerRow.addSubview(footer)

        let stack = NSStackView(views: [searchRow, divider, scrollView, footerDivider, footerRow])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)

        listHeight = scrollView.heightAnchor.constraint(equalToConstant: maxListHeight)

        // Preferred 560pt width, but `.defaultHigh` so the required ≤0.92×tile cap wins on
        // a narrow window rather than the two conflicting as required constraints.
        let cardWidth = card.widthAnchor.constraint(equalToConstant: 560)
        cardWidth.priority = .defaultHigh

        NSLayoutConstraint.activate([
            backdrop.leadingAnchor.constraint(equalTo: leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: trailingAnchor),
            backdrop.topAnchor.constraint(equalTo: topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: bottomAnchor),

            card.centerXAnchor.constraint(equalTo: centerXAnchor),
            card.centerYAnchor.constraint(equalTo: centerYAnchor),
            cardWidth,
            card.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.92),

            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            stack.topAnchor.constraint(equalTo: card.topAnchor),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor),

            searchRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            divider.widthAnchor.constraint(equalTo: stack.widthAnchor),
            footerDivider.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scrollView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            footerRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            footerRow.heightAnchor.constraint(equalToConstant: 34),
            footer.centerXAnchor.constraint(equalTo: footerRow.centerXAnchor),
            footer.centerYAnchor.constraint(equalTo: footerRow.centerYAnchor),
            listHeight,

            doc.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            doc.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            doc.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            rowsStack.topAnchor.constraint(equalTo: doc.topAnchor, constant: listVerticalInset),
            // Inset the rows so a selected row's highlight keeps a margin from the list
            // edges (and the overlay scroller) instead of touching them.
            rowsStack.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: 8),
            rowsStack.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -8),
            rowsStack.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -listVerticalInset),

            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.contentView.centerXAnchor),
            emptyLabel.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor, constant: 24),
        ])

        reloadRows()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Make the search field first responder — called by the host after presenting.
    func focusInitialResponder() {
        window?.makeFirstResponder(searchField)
        searchField.applyThemedCaret()  // the editor exists only once the field has focus
    }

    /// Spring the card in (fade + subtle scale about its center). Call after presenting.
    func animateIn() {
        superview?.layoutSubtreeIfNeeded()  // resolve the card's frame before scaling about its center
        Motion.springScaleFade(card, appearing: true)
    }

    /// Spring the card back out, then run `completion` (the host removes the overlay).
    /// Idempotent — a second call while already dismissing is ignored.
    func animateOut(completion: @escaping () -> Void) {
        guard dismiss.begin() else { return }
        Motion.springScaleFade(card, appearing: false, completion: completion)
    }

    /// Once dismissal starts, stop intercepting clicks so a tap during the exit animation
    /// falls through to the terminal instead of the still-present backdrop.
    override func hitTest(_ point: NSPoint) -> NSView? {
        dismiss.isDismissing ? nil : super.hitTest(point)
    }

    /// The card root owns Esc — inherited by both palettes. Claimed in `performKeyEquivalent` so
    /// every card agrees on one Esc owner, rather than each host deciding by accident; it also
    /// covers the search field, whose `cancelOperation` used to handle this separately.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if ModalEscape.handle(
            event, in: window, dismissing: dismiss.isDismissing, close: { self.onDismiss() }
        ) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Re-apply the card's theme-dependent colors after a live theme change: the retained shell
    /// (card fill/border, search glyph, search field text, divider, empty label, footer hints),
    /// then re-render the rows for the CURRENT query so per-row content (title/shortcut ink,
    /// name/git ink, add-row accent — all read fresh from `Theme.current` in the row builders)
    /// comes back correct too, for free. The typed query lives in `searchField`, untouched by
    /// this — nothing is lost. `reloadRows()` does reset the selection to the top as a normal
    /// side effect of any re-render; that's an acceptable trade for a theme swap.
    func reapplyTheme() {
        let chrome = Theme.current.chrome
        CardChrome.reapplyTheme(to: card)
        searchGlyph.textColor = chrome.ink(.muted)
        searchField.textColor = chrome.foreground.nsColor
        searchField.applyThemedCaret()  // the field holds focus across the swap, so re-tint in place
        applyPlaceholder()
        for hairline in [divider, footerDivider] {
            hairline.layer?.backgroundColor = chrome.fill(alpha: ChromeTheme.hairline).cgColor
        }
        emptyLabel.textColor = chrome.ink(.muted)
        footerHintLabels.forEach { $0.textColor = chrome.ink(.muted) }
        footerKeycaps.forEach { $0.reapplyTheme() }
        // Drop every built row first: the reload reuses a row whose identity survives, and a row
        // bakes its colors in at construction, so reusing one here would leave it in the old theme.
        laidOutRows.forEach { $0.view.removeFromSuperview() }
        laidOutRows = []
        applyFilter(query: searchField.stringValue)
        reloadRows()
    }

    /// The system `placeholderString` draws in AppKit's `placeholderTextColor`, which follows the
    /// view's `effectiveAppearance` rather than `Theme.current` — near-white on a light theme under
    /// a dark appearance. Build the placeholder as an attributed string colored from the chrome ink
    /// role instead, so it stays readable and re-derives on a live theme swap.
    private func applyPlaceholder() {
        searchField.placeholderAttributedString = NSAttributedString(
            string: searchPlaceholder,
            attributes: [
                .foregroundColor: Theme.current.chrome.ink(.muted),
                .font: searchField.font ?? .systemFont(ofSize: 15),
            ]
        )
    }

    // MARK: template hooks (subclass overrides)

    /// Number of rows for the current (filtered) model.
    func numberOfRows() -> Int { fatalError("subclass must override numberOfRows()") }

    /// Build the row view at `index`. The base wires the click itself (`onActivate`), so a row
    /// carries no index of its own.
    func makeRow(at index: Int) -> PaletteRowView { fatalError("subclass must override makeRow(at:)") }

    /// What makes the row at `index` the same row across a re-filter, so its view can be reused
    /// rather than rebuilt on every keystroke. Two rows sharing an identity must render identically
    /// — a row bakes its content in at construction, so the identity has to cover everything shown.
    /// nil means "never reuse this row", the safe default: identity by position would hand one
    /// row's baked-in content to a different model entry.
    func rowIdentity(at index: Int) -> AnyHashable? { nil }

    /// Height of the row at `index`. Defaults to the uniform row height; override to give
    /// some rows (e.g. section headers) a different height.
    func rowHeight(at index: Int) -> CGFloat { defaultRowHeight }

    /// Whether the row at `index` can be selected/activated. Non-selectable rows (e.g.
    /// section headers) are skipped by the arrow keys and ignored on click/Enter.
    func isSelectable(at index: Int) -> Bool { true }

    /// Recompute the filtered model for `query`. The base resets the selection and
    /// rebuilds rows around this call — implementations only update their own model.
    func applyFilter(query: String) { fatalError("subclass must override applyFilter(query:)") }

    /// Activate the row at `index`. `modifiers` carries the live event flags (e.g. Shift).
    func activate(index: Int, modifiers: NSEvent.ModifierFlags) {
        fatalError("subclass must override activate(index:modifiers:)")
    }

    // MARK: selection + list (base-owned)

    /// Run the row at `index` from a click: select it, then activate with the default action.
    /// Clicks on non-selectable rows (headers) are ignored. A click activates with no modifiers —
    /// modifier-qualified activation (e.g. Shift+Enter to replace) stays keyboard-only, matching
    /// the prior picker.
    func activateRow(at index: Int) {
        guard isSelectable(at: index) else { return }
        selected = index
        updateHighlight()
        activate(index: index, modifiers: [])
    }

    /// Re-render the list for the current filtered model, reusing the view of every row whose
    /// identity survived the filter. Typing runs this per keystroke, and rebuilding meant a fresh
    /// view tree (and, for a command row, a fresh `KeycapView` resolving SF Symbols) for every row
    /// on every character.
    ///
    /// A reused row stays in the view hierarchy throughout — `insertArrangedSubview` moves an
    /// already-arranged view, so the ordering falls out of the same loop. Detaching it instead
    /// would drop the width constraint (it crosses to the stack) while LEAVING the height
    /// constraint active (it's anchored to the row itself), so re-adding would stack up a second
    /// height constraint per reload.
    private func reloadRows() {
        var reusable: [AnyHashable: LaidOutRow] = [:]
        for row in laidOutRows {
            if let id = row.id { reusable[id] = row }
        }

        let count = numberOfRows()
        var next: [LaidOutRow] = []
        var total: CGFloat = 0
        for index in 0..<count {
            let height = rowHeight(at: index)
            let id = rowIdentity(at: index)
            // Positions 0..<index already hold `next`, so any row still waiting to be dropped sits
            // at or after `index` — inserting there lands each row at its final position.
            let row: LaidOutRow
            if let id, let reused = reusable.removeValue(forKey: id) {
                reused.height.constant = height
                rowsStack.insertArrangedSubview(reused.view, at: index)
                row = reused
            } else {
                let view = makeRow(at: index)
                rowsStack.insertArrangedSubview(view, at: index)  // width pins to the stack, so insert first
                let heightConstraint = view.heightAnchor.constraint(equalToConstant: height)
                NSLayoutConstraint.activate([
                    view.widthAnchor.constraint(equalTo: rowsStack.widthAnchor), heightConstraint,
                ])
                row = LaidOutRow(id: id, view: view, height: heightConstraint)
            }
            row.view.onActivate = { [weak self] in self?.activateRow(at: index) }
            next.append(row)
            total += height
        }

        let kept = Set(next.map { ObjectIdentifier($0.view) })
        for row in laidOutRows where !kept.contains(ObjectIdentifier(row.view)) {
            row.view.removeFromSuperview()
        }
        laidOutRows = next

        emptyLabel.isHidden = count != 0
        // Empty → keep a small fixed height so the "no results" label isn't clipped by a
        // zero-height scroll view.
        listHeight.constant = count == 0 ? emptyListHeight : min(total + 2 * listVerticalInset, maxListHeight)
        selected = defaultSelectionIndex()
        updateHighlight()
        scrollSelectedToVisible()
    }

    /// The laid-out row views, in list order — for a subclass that updates its rows in place (the
    /// repo picker's git badges, which land after a background probe) instead of re-rendering.
    var rowViews: [PaletteRowView] { laidOutRows.map(\.view) }

    /// The row highlighted after a (re)load — the first selectable row by default. A subclass
    /// overrides to prefer a different default (e.g. the repo picker highlights the first
    /// workspace, not its pinned ＋ row, so Enter opens a workspace).
    func defaultSelectionIndex() -> Int { firstSelectableIndex() }

    private func moveSelection(_ delta: Int) {
        let step = delta < 0 ? -1 : 1
        var i = selected + step
        // Skip over non-selectable rows (headers) in the direction of travel.
        while laidOutRows.indices.contains(i) {
            if isSelectable(at: i) {
                selected = i
                updateHighlight()
                scrollSelectedToVisible(travelling: step < 0 ? .up : .down)
                return
            }
            i += step
        }
    }

    /// The first selectable row, or 0 when there is none (empty list).
    private func firstSelectableIndex() -> Int {
        (0..<laidOutRows.count).first { isSelectable(at: $0) } ?? 0
    }

    private func updateHighlight() {
        for (i, row) in laidOutRows.enumerated() { row.view.isSelected = (i == selected) }
    }

    /// Reveal the selected row through the shared keyboard reveal, so a palette scrolls exactly like a
    /// Settings section: the section header above a group's first row comes with it, and the row lands
    /// inside the list rather than flush against the edge it arrived at. The stops are the selectable
    /// rows, which is what makes the headers between them read as a header rather than a stop.
    /// `travelling` is `.unknown` from a reload, where the selection was recomputed rather than moved.
    private func scrollSelectedToVisible(travelling: KeyboardFocus.Travel = .unknown) {
        guard laidOutRows.indices.contains(selected) else { return }
        let stops = laidOutRows.indices.filter { isSelectable(at: $0) }.map { laidOutRows[$0].view }
        KeyboardFocus.reveal(laidOutRows[selected].view, among: stops, travelling: travelling)
    }

    /// Build the footer: a centered horizontal row of hints, each a keycap box + its label.
    /// Returns the labels + keycaps it created too, so `init` can retain them for
    /// `reapplyTheme()` — the footer is built once and never rebuilt by a row re-render, so
    /// nothing here may be a throwaway local.
    private static func makeFooter(_ hints: [PaletteHint]) -> (
        view: NSStackView, labels: [NSTextField], keycaps: [KeycapView]
    ) {
        var labels: [NSTextField] = []
        var keycaps: [KeycapView] = []
        let items = hints.map { hint -> NSView in
            let keycap = KeycapView(shortcut: hint.keys)
            let label = NSTextField(labelWithString: hint.label)
            label.font = .systemFont(ofSize: 11, weight: .medium)
            label.textColor = Theme.current.chrome.ink(.muted)
            keycaps.append(keycap)
            labels.append(label)
            let item = NSStackView(views: [keycap, label])
            item.orientation = .horizontal
            item.spacing = 5
            item.alignment = .centerY
            return item
        }
        let stack = NSStackView(views: items)
        stack.orientation = .horizontal
        stack.spacing = 16
        stack.alignment = .centerY
        return (stack, labels, keycaps)
    }

}

extension PaletteOverlay: NSTextFieldDelegate {
    /// A click focuses the field without going through `focusInitialResponder`, and the field editor is
    /// shared per window, so it arrives carrying whatever tint the last field left on it.
    func controlTextDidBeginEditing(_ obj: Notification) {
        searchField.applyThemedCaret()
    }

    func controlTextDidChange(_ obj: Notification) {
        applyFilter(query: searchField.stringValue)
        reloadRows()  // resets the selection to the first selectable row
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(-1); return true
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(1); return true
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertLineBreak(_:)):
            guard laidOutRows.indices.contains(selected), isSelectable(at: selected) else { return true }
            activate(index: selected, modifiers: NSApp.currentEvent?.modifierFlags ?? [])
            return true
        default:
            return false
        }
    }
}
