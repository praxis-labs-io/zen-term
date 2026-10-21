import AppKit

struct CheckboxDropdownItem: Equatable {
    let title: String
    let isChecked: Bool
    let note: String?
    let symbol: String?

    init(title: String, isChecked: Bool, note: String? = nil, symbol: String? = nil) {
        self.title = title
        self.isChecked = isChecked
        self.note = note
        self.symbol = symbol
    }
}

final class CheckboxDropdown: NSView {
    private(set) var items: [CheckboxDropdownItem]
    private let onToggle: (Int) -> Void
    /// Fixed at init; `setItems` clamps to it so arrowing never reaches a row that was not rendered.
    private let rowCount: Int

    var onArrowUp: (() -> Void)?
    var onArrowDown: (() -> Void)?
    var onArrowLeft: (() -> Void)?
    var onTab: (() -> Void)?
    var onBacktab: (() -> Void)?
    var onClosed: (() -> Void)?

    private var summary: String
    private let titleLabel = NSTextField(labelWithString: "")
    private let queryField = NSTextField()
    private var isEditing = false
    private let chevron = NSImageView()
    /// A window resize closes the card without `closeList`, so the self-close hook repeats that cleanup.
    private lazy var popover: ListPopover = {
        let popover = ListPopover(anchor: self)
        popover.onSelfClose = { [weak self] in
            self?.rowViews = []
            self?.query = ""
            self?.endEditing()
            self?.renderTitle()
            self?.restyle()
            self?.fireClosed()
        }
        return popover
    }()
    private var rowViews: [CheckboxRowView] = []
    private var visible: [Int] = []
    private var query = ""
    private var highlighted = 0
    var restingIndices: [Int]?
    private var isFocusedStop = false

    private static let rowHeight: CGFloat = ChromeMetrics.Height.control

    var buttonTitleForTesting: String { titleLabel.stringValue }
    var isEditingForTesting: Bool { !queryField.isHidden }
    var shownSummaryForTesting: String? { titleLabel.isHidden ? nil : titleLabel.stringValue }
    var itemsForTesting: [CheckboxDropdownItem] { items }
    var isPopoverOpen: Bool { popover.isOpen }
    var highlightedIndexForTesting: Int { highlighted }
    var queryForTesting: String { query }
    var visibleIndicesForTesting: [Int] { visible }
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
        layer?.cornerRadius = ChromeMetrics.Radius.control
        PopoverButtonStyle.applyRestFill(to: self)
        layer?.borderWidth = ChromeMetrics.Border.width
        layer?.borderColor = Theme.current.chrome.fill(alpha: ChromeTheme.border).cgColor

        titleLabel.font = ChromeType.font(.body)
        titleLabel.textColor = Theme.current.chrome.ink(.normal)
        titleLabel.stringValue = title
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.lineBreakMode = .byTruncatingTail

        queryField.font = ChromeType.font(.body)
        queryField.textColor = Theme.current.chrome.ink(.normal)
        queryField.isBordered = false
        queryField.makeSingleLine()
        queryField.drawsBackground = false
        queryField.focusRingType = .none
        queryField.isHidden = true
        queryField.delegate = self
        queryField.translatesAutoresizingMaskIntoConstraints = false

        chevron.image = NSImage(systemSymbolName: "chevron.up.chevron.down", accessibilityDescription: nil)
        chevron.symbolConfiguration = .init(pointSize: ChromeMetrics.Icon.xs, weight: .semibold)
        chevron.contentTintColor = Theme.current.chrome.ink(.muted)
        chevron.translatesAutoresizingMaskIntoConstraints = false

        addSubview(titleLabel)
        addSubview(queryField)
        addSubview(chevron)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: ChromeMetrics.Height.control),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: ChromeMetrics.Spacing.controlInset),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            queryField.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            queryField.centerYAnchor.constraint(equalTo: centerYAnchor),
            queryField.trailingAnchor.constraint(equalTo: chevron.leadingAnchor, constant: -ChromeMetrics.Spacing.s6),
            chevron.leadingAnchor.constraint(
                greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: ChromeMetrics.Spacing.s6),
            chevron.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -ChromeMetrics.Spacing.controlInset),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func setItems(_ items: [CheckboxDropdownItem], title: String) {
        self.items = Array(items.prefix(rowCount))
        summary = title
        renderTitle()
        refreshRows()
    }

    func reapplyTheme() {
        restyle()
        renderTitle()
        chevron.contentTintColor = Theme.current.chrome.ink(.muted)
        queryField.textColor = Theme.current.chrome.ink(.normal)
        if isEditing { queryField.applyThemedEditor() }
        rebuildOpenList()
    }

    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool {
        showFocus()
        return true
    }
    /// Handing focus to the query field on open is not losing focus, or opening would close the list.
    override func resignFirstResponder() -> Bool {
        isFocusedStop = false
        if !isEditing { closeList() }
        restyle()
        return super.resignFirstResponder()
    }
    override func drawFocusRingMask() {}

    /// The open card lives on the window's content view, so it would outlive a torn-out ancestor.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { closeList() }
    }

    private func showFocus() {
        isFocusedStop = true
        restyle()
    }

    #if DEBUG
        func forceFocusForGallery() { showFocus() }
    #endif

    private func restyle() {
        PopoverButtonStyle.apply(to: self, isFocused: isFocusedStop, isOpen: popover.isOpen)
    }

    /// Fallback only: an open list normally holds focus in the query field, whose delegate routes its keys.
    override func keyDown(with event: NSEvent) {
        if popover.isOpen {
            switch KeyboardFocus.key(for: event) {
            case .up: moveHighlight(-1)
            case .down: moveHighlight(1)
            case .activate: toggleHighlight()
            case .escape: escapePressed()
            default: break
            }
            return
        }
        switch KeyboardFocus.key(for: event) {
        case .activate: openList()
        case .up: onArrowUp?()
        case .down: onArrowDown?()
        case .left where onArrowLeft != nil: onArrowLeft?()
        case .tab(let shift): shift ? onBacktab?() : onTab?()
        default: super.keyDown(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        if popover.isOpen {
            closeList()
            window?.makeFirstResponder(self)
        } else {
            window?.makeFirstResponder(self)
            openList()
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, alphaValue > 0 else { return nil }
        return bounds.contains(convert(point, from: superview)) ? self : nil
    }

    /// Guarded before `buildRows()`, which would leave the mounted rows pointing at views in no card.
    private func openList() {
        guard !popover.isOpen, window?.contentView != nil else { return }
        query = ""
        refilter()
        highlighted = visible.first ?? 0
        popover.open(rows: buildRows())
        refreshRows()
        beginEditing()
        restyle()
    }

    private func closeList() {
        let wasOpen = popover.isOpen
        popover.close()
        rowViews = []
        query = ""
        endEditing()
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

    private func escapePressed() {
        guard !query.isEmpty else { return closeList() }
        query = ""
        queryField.stringValue = ""
        rerenderList()
    }

    private func beginEditing() {
        queryField.stringValue = ""
        queryField.isHidden = false
        isEditing = true
        renderTitle()
        guard window?.makeFirstResponder(queryField) == true else { return endEditing() }
    }

    /// Restores focus before hiding the field: hiding a first responder dumps focus to the window.
    private func endEditing() {
        let wasEditing = isEditing
        isEditing = false
        if wasEditing, window?.firstResponder === queryField.currentEditor() { window?.makeFirstResponder(self) }
        queryField.isHidden = true
        renderTitle()
    }

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
            .sorted { $0.score == $1.score ? $0.index < $1.index : $0.score > $1.score }
            .map(\.index)
    }

    private func rebuildOpenList() {
        guard popover.isOpen else { return }
        popover.close()
        popover.open(rows: buildRows())
        refreshRows()
        if let position = visible.firstIndex(of: highlighted), rowViews.indices.contains(position) {
            popover.reveal(rowViews[position])
        }
    }

    private func rerenderList() {
        renderTitle()
        guard popover.isOpen else { return }
        let before = visible
        refilter()
        guard visible != before else { return }
        highlighted = visible.first ?? highlighted
        rebuildOpenList()
    }

    /// Stands in for the query field's placeholder while editing: setting a placeholder mid-edit ends the edit.
    private func renderTitle() {
        titleLabel.stringValue = summary
        titleLabel.textColor = Theme.current.chrome.ink(isEditing ? .muted : .normal)
        titleLabel.isHidden = isEditing && !query.isEmpty
    }

    private func moveHighlight(_ delta: Int) {
        let at = visible.firstIndex(of: highlighted)
        guard let next = KeyboardFocus.step(from: at, delta: delta, count: visible.count) else { return }
        highlighted = visible[next]
        refreshRows()
        guard rowViews.indices.contains(next) else { return }
        let row = rowViews[next]
        popover.reveal(row)
    }

    private func toggleHighlight() {
        guard visible.contains(highlighted) else { return }
        toggle(highlighted)
    }

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
        label.font = ChromeType.sectionLabel
        label.textColor = Theme.current.chrome.ink(.muted)
        label.translatesAutoresizingMaskIntoConstraints = false
        let host = NSView()
        host.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: ChromeMetrics.Spacing.controlInset),
            label.centerYAnchor.constraint(equalTo: host.centerYAnchor),
        ])
        return host
    }

    private final class CheckboxRowView: NSView {
        private let onClick: () -> Void
        private let check = NSImageView()
        private let title = NSTextField(labelWithString: "")
        private let note = NSTextField(labelWithString: "")
        private let icon = NSImageView()
        private lazy var iconWidth = icon.widthAnchor.constraint(equalToConstant: 0)
        private lazy var titleGap = title.leadingAnchor.constraint(equalTo: icon.trailingAnchor)

        init(onClick: @escaping () -> Void) {
            self.onClick = onClick
            super.init(frame: .zero)
            wantsLayer = true
            layer?.cornerRadius = ChromeMetrics.Radius.control
            translatesAutoresizingMaskIntoConstraints = false

            check.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)
            check.symbolConfiguration = .init(pointSize: 11, weight: .semibold)
            check.translatesAutoresizingMaskIntoConstraints = false
            title.font = ChromeType.font(.body)
            title.lineBreakMode = .byTruncatingTail
            title.translatesAutoresizingMaskIntoConstraints = false
            note.font = ChromeType.font(.caption)
            note.translatesAutoresizingMaskIntoConstraints = false
            note.setContentCompressionResistancePriority(.required, for: .horizontal)
            icon.symbolConfiguration = .init(pointSize: 11, weight: .regular)
            icon.translatesAutoresizingMaskIntoConstraints = false
            addSubview(check)
            addSubview(icon)
            addSubview(title)
            addSubview(note)
            NSLayoutConstraint.activate([
                check.leadingAnchor.constraint(equalTo: leadingAnchor, constant: ChromeMetrics.Spacing.controlInset),
                check.widthAnchor.constraint(equalToConstant: 14),
                check.centerYAnchor.constraint(equalTo: centerYAnchor),
                icon.leadingAnchor.constraint(equalTo: check.trailingAnchor, constant: ChromeMetrics.Spacing.s6),
                iconWidth,
                icon.centerYAnchor.constraint(equalTo: centerYAnchor),
                titleGap,
                title.trailingAnchor.constraint(
                    lessThanOrEqualTo: note.leadingAnchor, constant: -ChromeMetrics.Spacing.s8),
                title.centerYAnchor.constraint(equalTo: centerYAnchor),
                note.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -ChromeMetrics.Spacing.controlInset),
                note.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        func render(item: CheckboxDropdownItem, isHighlighted: Bool, chrome: ChromeTheme) {
            title.stringValue = item.title
            title.textColor = item.isChecked ? chrome.ink(.normal) : chrome.ink(.muted)
            note.stringValue = item.note ?? ""
            note.textColor = chrome.ink(.faint)
            note.isHidden = item.note == nil
            icon.image = item.symbol.flatMap {
                NSImage(systemSymbolName: $0, accessibilityDescription: nil)
            }
            icon.contentTintColor = item.isChecked ? chrome.accent.nsColor : chrome.ink(.subtle)
            icon.isHidden = item.symbol == nil
            iconWidth.constant = icon.isHidden ? 0 : 14
            titleGap.constant = icon.isHidden ? 0 : ChromeMetrics.Spacing.s6
            check.isHidden = !item.isChecked
            check.contentTintColor = chrome.accent.nsColor
            layer?.backgroundColor = (isHighlighted ? chrome.fill(.hover) : NSColor.clear).cgColor
        }

        override func mouseDown(with event: NSEvent) { onClick() }
    }
}

extension CheckboxDropdown: NSTextFieldDelegate {
    func controlTextDidEndEditing(_ obj: Notification) {
        guard isEditing, window?.firstResponder !== self else { return }
        closeList()
    }

    func controlTextDidChange(_ obj: Notification) {
        query = queryField.stringValue
        rerenderList()
    }

    /// Takes Tab back from the field editor: `selectNextKeyView` would land focus on the hidden field.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveUp(_:)): moveHighlight(-1)
        case #selector(NSResponder.moveDown(_:)): moveHighlight(1)
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertLineBreak(_:)):
            toggleHighlight()
        case #selector(NSResponder.cancelOperation(_:)): escapePressed()
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
