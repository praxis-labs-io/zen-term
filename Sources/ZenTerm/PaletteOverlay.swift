import AppKit

/// A row inside a palette list. The overlay drives selection highlighting through this.
protocol PaletteRowView: NSView {
    var isSelected: Bool { get set }
}

/// One footer hint: a key glyph string (rendered as a keycap, same as a row's shortcut)
/// and the action it performs. e.g. `PaletteHint(keys: "⏎", label: "run")`.
struct PaletteHint {
    let keys: String
    let label: String
}

/// A selectable palette row with the shared selection chrome: rounded corners, an iris
/// highlight when selected, and click forwarding (`clickCount` distinguishes single from
/// double click). Subclasses add their own content in `init` after calling `super.init`.
class SelectableRowView: NSView, PaletteRowView {
    private let onClick: (Int) -> Void
    var isSelected = false { didSet { updateBackground() } }

    init(onClick: @escaping (Int) -> Void) {
        self.onClick = onClick
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func mouseDown(with event: NSEvent) { onClick(event.clickCount) }

    private func updateBackground() {
        layer?.backgroundColor = (isSelected ? PaletteOverlay.selectionBackground : .clear).cgColor
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
    private var isDismissing = false
    private let searchGlyph = NSTextField(labelWithString: "⌕")
    private let searchField = NSTextField()
    private let searchPlaceholder: String
    private let divider = NSView()
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
    private var rowViews: [PaletteRowView] = []
    private var selected = 0

    /// The selection highlight shared by every palette row (accent @ 18%).
    static var selectionBackground: NSColor {
        Theme.current.chrome.accent.nsColor.withAlphaComponent(0.18)
    }

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

        card.wantsLayer = true
        card.layer?.cornerRadius = 12
        card.layer?.backgroundColor = background.cgColor
        card.layer?.borderWidth = 1
        card.layer?.borderColor = FloatShadow.edge.cgColor
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)
        // Dark elevation shadow on the card itself (masksToBounds stays off so it isn't
        // clipped); the list clips its own rows, so nothing overflows the rounded corners.
        FloatShadow.applyShadow(to: card)

        // Search row: a magnifier glyph + a borderless field.
        searchGlyph.font = .systemFont(ofSize: 16)
        searchGlyph.textColor = Theme.current.chrome.ink(alpha: 0.4)
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

        divider.wantsLayer = true
        divider.layer?.backgroundColor = Theme.current.chrome.ink(alpha: 0.08).cgColor
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.heightAnchor.constraint(equalToConstant: 1).isActive = true

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
        emptyLabel.textColor = Theme.current.chrome.ink(alpha: 0.4)
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

        let stack = NSStackView(views: [searchRow, divider, scrollView, footerRow])
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
    func focusInitialResponder() { window?.makeFirstResponder(searchField) }

    /// Spring the card in (fade + subtle scale about its center). Call after presenting.
    func animateIn() {
        superview?.layoutSubtreeIfNeeded()  // resolve the card's frame before scaling about its center
        Motion.springScaleFade(card, appearing: true)
    }

    /// Spring the card back out, then run `completion` (the host removes the overlay).
    /// Idempotent — a second call while already dismissing is ignored.
    func animateOut(completion: @escaping () -> Void) {
        guard !isDismissing else { return }
        isDismissing = true
        Motion.springScaleFade(card, appearing: false, completion: completion)
    }

    /// Once dismissal starts, stop intercepting clicks so a tap during the exit animation
    /// falls through to the terminal instead of the still-present backdrop.
    override func hitTest(_ point: NSPoint) -> NSView? {
        isDismissing ? nil : super.hitTest(point)
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
        card.layer?.backgroundColor = chrome.background.nsColor.cgColor
        card.layer?.borderColor = FloatShadow.edge.cgColor
        searchGlyph.textColor = chrome.ink(alpha: 0.4)
        searchField.textColor = chrome.foreground.nsColor
        applyPlaceholder()
        divider.layer?.backgroundColor = chrome.ink(alpha: 0.08).cgColor
        emptyLabel.textColor = chrome.ink(alpha: 0.4)
        footerHintLabels.forEach { $0.textColor = chrome.ink(alpha: 0.5) }
        footerKeycaps.forEach { $0.reapplyTheme() }
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
                .foregroundColor: Theme.current.chrome.ink(alpha: 0.4),
                .font: searchField.font ?? .systemFont(ofSize: 15),
            ]
        )
    }

    // MARK: template hooks (subclass overrides)

    /// Number of rows for the current (filtered) model.
    func numberOfRows() -> Int { fatalError("subclass must override numberOfRows()") }

    /// Build the row view at `index`. Wire its click via `selectRow(at:clickCount:)`.
    func makeRow(at index: Int) -> PaletteRowView { fatalError("subclass must override makeRow(at:)") }

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

    /// Row click handler subclasses route their row taps to: single click selects,
    /// double click activates. Clicks on non-selectable rows (headers) are ignored.
    /// A double-click activates with the default action (no modifiers) — modifier-qualified
    /// activation (e.g. Shift+Enter to replace) is keyboard-only, matching the prior picker.
    func selectRow(at index: Int, clickCount: Int) {
        guard isSelectable(at: index) else { return }
        selected = index
        updateHighlight()
        if clickCount >= 2 { activate(index: index, modifiers: []) }
    }

    private func reloadRows() {
        rowViews.forEach { $0.removeFromSuperview() }
        let count = numberOfRows()
        var total: CGFloat = 0
        rowViews = (0..<count).map { i in
            let row = makeRow(at: i)
            rowsStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
            row.heightAnchor.constraint(equalToConstant: rowHeight(at: i)).isActive = true
            total += rowHeight(at: i)
            return row
        }
        emptyLabel.isHidden = count != 0
        // Empty → keep a small fixed height so the "no results" label isn't clipped by a
        // zero-height scroll view.
        listHeight.constant = count == 0 ? emptyListHeight : min(total + 2 * listVerticalInset, maxListHeight)
        selected = defaultSelectionIndex()
        updateHighlight()
        scrollSelectedToVisible()
    }

    /// The row highlighted after a (re)load — the first selectable row by default. A subclass
    /// overrides to prefer a different default (e.g. the repo picker highlights the first
    /// workspace, not its pinned ＋ row, so Enter opens a workspace).
    func defaultSelectionIndex() -> Int { firstSelectableIndex() }

    private func moveSelection(_ delta: Int) {
        let step = delta < 0 ? -1 : 1
        var i = selected + step
        // Skip over non-selectable rows (headers) in the direction of travel.
        while rowViews.indices.contains(i) {
            if isSelectable(at: i) {
                selected = i
                updateHighlight()
                scrollSelectedToVisible()
                return
            }
            i += step
        }
    }

    /// The first selectable row, or 0 when there is none (empty list).
    private func firstSelectableIndex() -> Int {
        (0..<rowViews.count).first { isSelectable(at: $0) } ?? 0
    }

    private func updateHighlight() {
        for (i, row) in rowViews.enumerated() { row.isSelected = (i == selected) }
    }

    private func scrollSelectedToVisible() {
        guard rowViews.indices.contains(selected) else { return }
        let y = (0..<selected).reduce(listVerticalInset) { $0 + rowHeight(at: $1) }
        (scrollView.documentView as? FlippedView)?
            .scrollToVisible(CGRect(x: 0, y: y, width: 1, height: rowHeight(at: selected)))
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
            label.textColor = Theme.current.chrome.ink(alpha: 0.5)
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
        case #selector(NSResponder.cancelOperation(_:)):
            onDismiss(); return true
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertLineBreak(_:)):
            guard rowViews.indices.contains(selected), isSelectable(at: selected) else { return true }
            activate(index: selected, modifiers: NSApp.currentEvent?.modifierFlags ?? [])
            return true
        default:
            return false
        }
    }
}
