import AppKit

protocol PaletteRowView: NSView {
    var isSelected: Bool { get set }
    var onActivate: (() -> Void)? { get set }
}

struct PaletteHint {
    let keys: String
    let label: String
}

class SelectableRowView: NSView, PaletteRowView {
    var onActivate: (() -> Void)?
    var isSelected = false { didSet { updateBackground() } }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Accepts the press so the release lands here; `mouseUp` runs the row only if it lands inside.
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onActivate?() }
    }

    private func updateBackground() {
        layer?.backgroundColor = (isSelected ? Theme.current.chrome.selectionFill : .clear).cgColor
    }
}

class PaletteOverlay: NSView, ModalOverlay {
    private let onDismiss: () -> Void

    private let card = CardView()
    private var dismiss = DismissGate()
    private let searchGlyph = NSTextField(labelWithString: "⌕")
    private let searchField = NSTextField()
    private let searchPlaceholder: String
    private let divider = NSView()
    private let footerDivider = NSView()
    private let rowsStack = NSStackView()
    private let scrollView = NSScrollView()
    private let emptyLabel: NSTextField
    private var footerHintLabels: [NSTextField] = []
    private var footerHintItems: [String: NSView] = [:]
    private var footerKeycaps: [KeycapView] = []
    private let defaultRowHeight: CGFloat
    private let maxListHeight: CGFloat
    private let emptyListHeight: CGFloat
    private let listVerticalInset: CGFloat = 8
    private var listHeight: NSLayoutConstraint!
    private struct LaidOutRow {
        let id: AnyHashable?
        let view: PaletteRowView
        let height: NSLayoutConstraint
    }
    private var laidOutRows: [LaidOutRow] = []
    private(set) var selected = 0
    private var animatesNextReload = false

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

        let backdrop = BackdropView(onClick: onDismiss)
        backdrop.wantsLayer = true
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        addSubview(backdrop)

        CardChrome.apply(to: card, background: background)
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)

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

        rowsStack.orientation = .vertical
        rowsStack.spacing = 0
        rowsStack.alignment = .leading
        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(rowsStack)
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
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

        let (footer, footerLabels, footerKeycaps, footerItems) = Self.makeFooter(footerHints)
        self.footerHintLabels = footerLabels
        self.footerKeycaps = footerKeycaps
        self.footerHintItems = footerItems
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
            rowsStack.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: 8),
            rowsStack.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -8),
            rowsStack.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -listVerticalInset),

            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.contentView.centerXAnchor),
            emptyLabel.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor, constant: 24),
        ])

        reloadRows()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func focusInitialResponder() { focusQuery() }

    func focusQuery() {
        window?.makeFirstResponder(searchField)
        searchField.applyThemedCaret()
    }

    func animateIn() {
        superview?.layoutSubtreeIfNeeded()
        Motion.springScaleFade(card, appearing: true)
    }

    func animateOut(completion: @escaping () -> Void) {
        guard dismiss.begin() else { return }
        Motion.springScaleFade(card, appearing: false, completion: completion)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        dismiss.isDismissing ? nil : super.hitTest(point)
    }

    /// Declared on the class: a protocol-extension default would bind statically in `performKeyEquivalent`.
    var isShowingOverlaidCard: Bool { false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if !isShowingOverlaidCard,
            ModalEscape.handle(
                event, in: window, dismissing: dismiss.isDismissing, close: { self.onDismiss() })
        {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    func reapplyTheme() {
        let chrome = Theme.current.chrome
        CardChrome.reapplyTheme(to: card)
        searchGlyph.textColor = chrome.ink(.muted)
        searchField.textColor = chrome.foreground.nsColor
        searchField.applyThemedCaret()
        applyPlaceholder()
        for hairline in [divider, footerDivider] {
            hairline.layer?.backgroundColor = chrome.fill(alpha: ChromeTheme.hairline).cgColor
        }
        emptyLabel.textColor = chrome.ink(.muted)
        footerHintLabels.forEach { $0.textColor = chrome.ink(.muted) }
        footerKeycaps.forEach { $0.reapplyTheme() }
        laidOutRows.forEach { $0.view.removeFromSuperview() }
        laidOutRows = []
        applyFilter(query: searchField.stringValue)
        reloadRows()
    }

    /// `placeholderString` draws in `placeholderTextColor`, which follows `effectiveAppearance`, not `Theme.current`.
    private func applyPlaceholder() {
        searchField.placeholderAttributedString = NSAttributedString(
            string: searchPlaceholder,
            attributes: [
                .foregroundColor: Theme.current.chrome.ink(.muted),
                .font: searchField.font ?? .systemFont(ofSize: 15),
            ]
        )
    }

    func numberOfRows() -> Int { fatalError("subclass must override numberOfRows()") }

    func makeRow(at index: Int) -> PaletteRowView { fatalError("subclass must override makeRow(at:)") }

    /// Nil by default: reuse by position would hand one row's baked-in content to a different entry.
    func rowIdentity(at index: Int) -> AnyHashable? { nil }

    func rowHeight(at index: Int) -> CGFloat { defaultRowHeight }

    func isSelectable(at index: Int) -> Bool { true }

    func applyFilter(query: String) { fatalError("subclass must override applyFilter(query:)") }

    func activate(index: Int, modifiers: NSEvent.ModifierFlags) {
        fatalError("subclass must override activate(index:modifiers:)")
    }

    func activateRow(at index: Int) {
        guard isSelectable(at: index) else { return }
        selected = index
        updateHighlight()
        activate(index: index, modifiers: [])
    }

    /// Reused rows stay arranged: detaching drops the width constraint but keeps the height one, stacking a duplicate.
    private func reloadRows() {
        var reusable: [AnyHashable: LaidOutRow] = [:]
        for row in laidOutRows {
            if let id = row.id { reusable[id] = row }
        }

        let count = numberOfRows()
        var next: [LaidOutRow] = []
        var arrived: [PaletteRowView] = []
        var total: CGFloat = 0
        for index in 0..<count {
            let height = rowHeight(at: index)
            let id = rowIdentity(at: index)
            let row: LaidOutRow
            if let id, let reused = reusable.removeValue(forKey: id) {
                reused.height.constant = height
                rowsStack.insertArrangedSubview(reused.view, at: index)
                row = reused
            } else {
                let view = makeRow(at: index)
                if animatesNextReload { arrived.append(view) }
                rowsStack.insertArrangedSubview(view, at: index)
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
        setListHeight(count == 0 ? emptyListHeight : min(total + 2 * listVerticalInset, maxListHeight))
        selected = defaultSelectionIndex()
        updateHighlight()
        scrollSelectedToVisible()
        for row in arrived {
            row.wantsLayer = true
            row.layer?.opacity = 0
            Motion.fade(row, to: 1)
        }
    }

    private func setListHeight(_ height: CGFloat) {
        guard animatesNextReload, !Motion.isReduceMotionEnabled() else {
            listHeight.constant = height
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Motion.fadeDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            listHeight.animator().constant = height
        }
    }

    var rowViews: [PaletteRowView] { laidOutRows.map(\.view) }

    var currentQuery: String { searchField.stringValue }

    func refreshRows(animated: Bool = false) {
        animatesNextReload = animated
        reloadRows()
        animatesNextReload = false
    }

    func reselect(byIdentity identity: AnyHashable?, near heldIndex: Int) {
        guard let identity else { return }
        let anchor = laidOutRows.firstIndex { $0.id == identity } ?? heldIndex
        guard let index = nearestSelectableIndex(to: anchor) else { return }
        selected = index
        updateHighlight()
        scrollSelectedToVisible()
    }

    private func nearestSelectableIndex(to anchor: Int) -> Int? {
        let start = min(max(anchor, 0), laidOutRows.count)
        return (start..<laidOutRows.count).first { isSelectable(at: $0) }
            ?? (0..<start).reversed().first { isSelectable(at: $0) }
    }

    func defaultSelectionIndex() -> Int { firstSelectableIndex() }

    private func moveSelection(_ delta: Int) {
        let step = delta < 0 ? -1 : 1
        var i = selected + step
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

    private func firstSelectableIndex() -> Int {
        (0..<laidOutRows.count).first { isSelectable(at: $0) } ?? 0
    }

    private func updateHighlight() {
        for (i, row) in laidOutRows.enumerated() { row.view.isSelected = (i == selected) }
        selectionChanged()
    }

    func selectionChanged() {}

    func setFooterHint(_ label: String, isShown: Bool) {
        footerHintItems[label]?.isHidden = !isShown
    }

    private func scrollSelectedToVisible(travelling: KeyboardFocus.Travel = .unknown) {
        guard laidOutRows.indices.contains(selected) else { return }
        let stops = laidOutRows.indices.filter { isSelectable(at: $0) }.map { laidOutRows[$0].view }
        KeyboardFocus.reveal(laidOutRows[selected].view, among: stops, travelling: travelling)
    }

    private static func makeFooter(_ hints: [PaletteHint]) -> (
        view: NSStackView, labels: [NSTextField], keycaps: [KeycapView], items: [String: NSView]
    ) {
        var labels: [NSTextField] = []
        var keycaps: [KeycapView] = []
        var byLabel: [String: NSView] = [:]
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
            byLabel[hint.label] = item
            return item
        }
        let stack = NSStackView(views: items)
        stack.orientation = .horizontal
        stack.spacing = 16
        stack.alignment = .centerY
        return (stack, labels, keycaps, byLabel)
    }

}

extension PaletteOverlay: NSTextFieldDelegate {
    /// A click focuses the field past `focusInitialResponder`, and the shared field editor keeps the last field's tint.
    func controlTextDidBeginEditing(_ obj: Notification) {
        searchField.applyThemedCaret()
    }

    func controlTextDidChange(_ obj: Notification) {
        applyFilter(query: searchField.stringValue)
        reloadRows()
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
