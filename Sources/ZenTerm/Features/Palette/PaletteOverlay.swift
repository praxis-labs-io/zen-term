import AppKit

protocol PaletteRowView: NSView {
    var isSelected: Bool { get set }
    var onActivate: (() -> Void)? { get set }
}

class SelectableRowView: NSView, PaletteRowView {
    var onActivate: (() -> Void)?
    var isSelected = false { didSet { updateBackground() } }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = ChromeMetrics.Radius.control
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Accepts the press so the release lands here; `mouseUp` runs the row only if it lands inside.
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onActivate?() }
    }

    private func updateBackground() {
        layer?.backgroundColor = (isSelected ? Theme.current.chrome.fill(.hover) : .clear).cgColor
    }
}

class PaletteOverlay: ModalShell, ModalOverlay {
    static let width: CGFloat = 560
    // NSStackView holds the search row's vertical insets at 250, so the list yields first only from below that.
    private static let listHeightPriority = NSLayoutConstraint.Priority(
        NSLayoutConstraint.Priority.defaultLow.rawValue - 1)

    private let searchGlyph = NSTextField(labelWithString: "⌕")
    private let searchField = NSTextField()
    private let searchPlaceholder: String
    private let divider = NSView()
    private let rowsStack = NSStackView()
    private let scrollView: FadingScrollView
    private let emptyLabel: NSTextField
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
        placeholder: String, emptyText: String, footerHints: [HintFooter.Hint],
        rowHeight: CGFloat, maxListHeight: CGFloat = 320, emptyListHeight: CGFloat = ChromeMetrics.Height.xl,
        onDismiss: @escaping () -> Void
    ) {
        self.defaultRowHeight = rowHeight
        self.maxListHeight = maxListHeight
        self.emptyListHeight = emptyListHeight
        self.emptyLabel = NSTextField(labelWithString: emptyText)
        self.searchPlaceholder = placeholder
        self.footer = HintFooter(footerHints)
        let doc = FlippedView()
        self.scrollView = FadingScrollView(document: doc)
        super.init(width: Self.width, onCancel: onDismiss)

        searchGlyph.font = ChromeType.font(.title, weight: .regular)
        searchGlyph.textColor = Theme.current.chrome.ink(.muted)
        searchField.font = ChromeType.font(.title, weight: .regular)
        applyPlaceholder()
        searchField.isBordered = false
        searchField.makeSingleLine()
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.textColor = Theme.current.chrome.ink(.normal)
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false
        let searchRow = NSStackView(views: [searchGlyph, searchField])
        searchRow.orientation = .horizontal
        searchRow.spacing = ChromeMetrics.Spacing.s8
        searchRow.edgeInsets = NSEdgeInsets(
            top: ChromeMetrics.Spacing.s12, left: ChromeMetrics.Spacing.s12, bottom: ChromeMetrics.Spacing.s12,
            right: ChromeMetrics.Spacing.s12)

        for hairline in [divider] {
            hairline.wantsLayer = true
            hairline.layer?.backgroundColor = Theme.current.chrome.fill(alpha: ChromeTheme.hairline).cgColor
            hairline.translatesAutoresizingMaskIntoConstraints = false
            hairline.heightAnchor.constraint(equalToConstant: ChromeMetrics.Border.width).isActive = true
        }

        rowsStack.orientation = .vertical
        rowsStack.spacing = 0
        rowsStack.alignment = .leading
        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(rowsStack)

        emptyLabel.font = ChromeType.font(.body)
        emptyLabel.textColor = Theme.current.chrome.ink(.muted)
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
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
        searchGlyph.textColor = chrome.ink(.muted)
        searchField.textColor = chrome.ink(.normal)
        searchField.applyThemedEditor()
        applyPlaceholder()
        for hairline in [divider] {
            hairline.layer?.backgroundColor = chrome.fill(alpha: ChromeTheme.hairline).cgColor
        }
        emptyLabel.textColor = chrome.ink(.muted)
        footer.reapplyTheme()
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
        footer.setHint(label, isShown: isShown)
    }

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
