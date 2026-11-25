import AppKit

protocol PaletteRowView: NSView {
    var isSelected: Bool { get set }
    var onActivate: (() -> Void)? { get set }
}

class SelectableRowView: ListRow, PaletteRowView {
    static let detailMaxWidth: CGFloat = 220

    static let detailMinWidth: CGFloat = 120

    // Below the title's compression resistance, so a long detail gives way to its floor before the title truncates.
    private static let detailYield = NSLayoutConstraint.Priority(NSLayoutConstraint.Priority.defaultLow.rawValue - 1)

    var onActivate: (() -> Void)? {
        get { onChoose }
        set { onChoose = newValue ?? {} }
    }
    var isSelected: Bool {
        get { isHighlighted }
        set { isHighlighted = newValue }
    }

    let detailLabel = NSTextField(labelWithString: "")
    private var detailFloor: NSLayoutConstraint!

    var detail: String {
        get { detailLabel.stringValue }
        set {
            detailLabel.stringValue = newValue
            detailLabel.isHidden = newValue.isEmpty
            detailFloor.constant = min(detailLabel.intrinsicContentSize.width, Self.detailMinWidth)
        }
    }

    init(_ content: Content, detail: String = "") {
        super.init(content) {}
        detailLabel.font = ChromeType.font(.caption)
        detailLabel.alignment = .right
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.setContentHuggingPriority(.required, for: .horizontal)
        detailLabel.setContentCompressionResistancePriority(Self.detailYield, for: .horizontal)
        detailFloor = detailLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 0)
        detailFloor.priority = .defaultHigh
        NSLayoutConstraint.activate([
            detailLabel.widthAnchor.constraint(lessThanOrEqualToConstant: Self.detailMaxWidth), detailFloor,
        ])
        self.detail = detail
        accessories = [detailLabel]
        applyDetailInk()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func reapplyTheme() {
        super.reapplyTheme()
        applyDetailInk()
    }

    private func applyDetailInk() { detailLabel.textColor = Theme.current.chrome.ink(.muted) }
}

class PaletteOverlay: ModalShell, ModalOverlay {
    static let width: CGFloat = 560
    static let actionsHint = HintFooter.Hint(keys: "⌘K", label: "Actions")
    private static let returnKey = "⏎"
    private static let searchInset = ChromeMetrics.Spacing.s12
    // NSStackView holds the search row's vertical insets at 250, so the list yields first only from below that.
    private static let listHeightPriority = NSLayoutConstraint.Priority(
        NSLayoutConstraint.Priority.defaultLow.rawValue - 1)

    private let searchGlyph = NSImageView()
    private let searchField = NSTextField()
    private let searchRow = NSStackView()
    private let searchPlaceholder: String
    private let divider = Divider()
    private let rowsStack = NSStackView()
    private let scrollView: FadingScrollView
    private let emptyLabel: EmptyStateLabel
    private let footer: HintFooter
    private let defaultRowHeight: CGFloat
    private let maxListHeight: CGFloat
    private let emptyListHeight: CGFloat
    private let listVerticalInset: CGFloat = ChromeMetrics.Spacing.s8
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
        placeholder: String, emptyText: String, rowHeight: CGFloat, maxListHeight: CGFloat = 320,
        emptyListHeight: CGFloat = ChromeMetrics.Height.xl, onDismiss: @escaping () -> Void
    ) {
        self.defaultRowHeight = rowHeight
        self.maxListHeight = maxListHeight
        self.emptyListHeight = emptyListHeight
        self.emptyLabel = EmptyStateLabel(emptyText)
        self.searchPlaceholder = placeholder
        self.footer = HintFooter([], trailingInset: Self.searchInset)
        let doc = FlippedView()
        self.scrollView = FadingScrollView(document: doc)
        super.init(width: Self.width, placement: .pinnedTop, onCancel: onDismiss)

        searchGlyph.image = IconCatalog.image("magnifyingglass", pointSize: ChromeMetrics.Icon.md, weight: .regular)
        searchGlyph.contentTintColor = Theme.current.chrome.ink(.muted)
        searchGlyph.setContentHuggingPriority(.required, for: .horizontal)
        searchField.font = ChromeType.font(.title, weight: .regular)
        applyPlaceholder()
        searchField.isBordered = false
        searchField.makeSingleLine()
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.textColor = Theme.current.chrome.ink(.normal)
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchRow.setViews([searchGlyph, searchField], in: .leading)
        searchRow.orientation = .horizontal
        searchRow.alignment = .centerY
        searchRow.spacing = ChromeMetrics.Spacing.s8
        searchRow.edgeInsets = NSEdgeInsets(top: 0, left: Self.searchInset, bottom: 0, right: Self.searchInset)

        rowsStack.orientation = .vertical
        rowsStack.spacing = 0
        rowsStack.alignment = .leading
        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(rowsStack)

        emptyLabel.alignment = .center
        emptyLabel.isHidden = true
        scrollView.contentView.addSubview(emptyLabel)

        let stack = NSStackView(views: [searchRow, divider, scrollView, footer])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .leading
        embed(stack)

        listHeight = scrollView.heightAnchor.constraint(equalToConstant: maxListHeight)
        listHeight.priority = Self.listHeightPriority

        NSLayoutConstraint.activate([
            searchRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            searchRow.heightAnchor.constraint(equalToConstant: ChromeMetrics.Height.xl),
            divider.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scrollView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor),
            listHeight,

            doc.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            doc.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            doc.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            rowsStack.topAnchor.constraint(equalTo: doc.topAnchor, constant: listVerticalInset),
            rowsStack.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: ChromeMetrics.Spacing.s8),
            rowsStack.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -ChromeMetrics.Spacing.s8),
            rowsStack.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -listVerticalInset),

            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.contentView.centerXAnchor),
            emptyLabel.leadingAnchor.constraint(
                greaterThanOrEqualTo: scrollView.contentView.leadingAnchor, constant: Self.searchInset),
            emptyLabel.topAnchor.constraint(
                equalTo: scrollView.contentView.topAnchor, constant: ChromeMetrics.Spacing.s20),
        ])

        reloadRows()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func focusInitialResponder() { focusQuery() }

    func focusQuery() {
        window?.makeFirstResponder(searchField)
    }

    override func reapplyTheme() {
        super.reapplyTheme()
        let chrome = Theme.current.chrome
        searchGlyph.contentTintColor = chrome.ink(.muted)
        searchField.textColor = chrome.ink(.normal)
        searchField.applyThemedEditor()
        applyPlaceholder()
        emptyLabel.reapplyTheme()
        reapplyKeymap()
    }

    func reapplyKeymap() {
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
                .font: searchField.font ?? ChromeType.font(.title, weight: .regular),
            ]
        )
    }

    var searchAccessory: NSView? {
        didSet {
            guard searchAccessory !== oldValue else { return }
            oldValue?.removeFromSuperview()
            if let searchAccessory { searchRow.setViews([searchAccessory], in: .trailing) }
        }
    }

    func numberOfRows() -> Int { fatalError("subclass must override numberOfRows()") }

    func makeRow(at index: Int) -> PaletteRowView { fatalError("subclass must override makeRow(at:)") }

    /// Nil by default: reuse by position would hand one row's baked-in content to a different entry.
    func rowIdentity(at index: Int) -> AnyHashable? { nil }

    func rowHeight(at index: Int) -> CGFloat { defaultRowHeight }

    func isSelectable(at index: Int) -> Bool { true }

    func returnAction(at index: Int) -> String? { nil }

    func hasMoreActions(at index: Int) -> Bool { false }

    func shortcutHints(at index: Int) -> [HintFooter.Hint] { [] }

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
            (row.view as? ListRow)?.onPointerEnter = { [weak self] in self?.pointRow(at: index) }
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
        let selectable = laidOutRows.indices.filter { isSelectable(at: $0) }
        guard
            let next = KeyboardFocus.step(
                from: selectable.firstIndex(of: selected), delta: delta, count: selectable.count)
        else { return }
        selected = selectable[next]
        updateHighlight()
        scrollSelectedToVisible(travelling: delta < 0 ? .up : .down)
    }

    private func pointRow(at index: Int) {
        guard index != selected, laidOutRows.indices.contains(index), isSelectable(at: index) else { return }
        selected = index
        updateHighlight()
    }

    private func firstSelectableIndex() -> Int {
        (0..<laidOutRows.count).first { isSelectable(at: $0) } ?? 0
    }

    private func updateHighlight() {
        for (i, row) in laidOutRows.enumerated() { row.view.isSelected = (i == selected) }
        refreshBar()
    }

    private func refreshBar() {
        guard laidOutRows.indices.contains(selected), isSelectable(at: selected),
            let action = returnAction(at: selected)
        else { return footer.setHints([]) }
        var hints = [HintFooter.Hint(keys: Self.returnKey, label: action)] + shortcutHints(at: selected)
        if hasMoreActions(at: selected) { hints.append(Self.actionsHint) }
        footer.setHints(hints)
    }

    var barHintsForTesting: [HintFooter.Hint] { footer.hints }

    private func scrollSelectedToVisible(travelling: KeyboardFocus.Travel = .unknown) {
        guard laidOutRows.indices.contains(selected) else { return }
        let stops = laidOutRows.indices.filter { isSelectable(at: $0) }.map { laidOutRows[$0].view }
        KeyboardFocus.reveal(laidOutRows[selected].view, among: stops, travelling: travelling)
    }
}

extension PaletteOverlay: NSTextFieldDelegate {
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
