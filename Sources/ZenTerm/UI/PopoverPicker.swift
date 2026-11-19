import AppKit

class PopoverPicker: NSView {
    var onArrowUp: (() -> Void)?
    var onArrowDown: (() -> Void)?
    var onArrowLeft: (() -> Void)?
    var onTab: (() -> Void)?
    var onBacktab: (() -> Void)?

    var title = "" { didSet { renderTitle() } }
    var highlighted = 0
    private(set) var query = ""
    private(set) var visible: [Int] = []

    let titleLabel = NSTextField(labelWithString: "")
    private(set) lazy var titleLeading = titleLabel.leadingAnchor.constraint(
        equalTo: leadingAnchor, constant: ChromeMetrics.Spacing.controlInset)
    private let queryField = NSTextField()
    private let chevron = NSImageView()
    /// A window resize closes the card without `closeList`, so the self-close hook repeats that cleanup.
    private lazy var popover: ListPopover = {
        let popover = ListPopover(anchor: self)
        popover.onSelfClose = { [weak self] in self?.finishClosing() }
        return popover
    }()
    private var isEditing = false
    private var isFocusedStop = false

    static let rowHeight: CGFloat = ChromeMetrics.Height.control

    var isPopoverOpen: Bool { popover.isOpen }
    var buttonTitleForTesting: String { titleLabel.stringValue }
    var isEditingForTesting: Bool { !queryField.isHidden }
    var queryForTesting: String { query }
    var visibleIndicesForTesting: [Int] { visible }
    var highlightedIndexForTesting: Int { highlighted }
    var listCardSizeForTesting: NSSize { popover.cardFrame.size }
    var listCardFrameForTesting: NSRect { popover.cardFrame }
    var queryFieldTextColorForTesting: NSColor? { queryField.textColor }
    func openListForTesting() { openList() }
    func moveHighlightForTesting(_ delta: Int) { moveHighlight(delta) }

    func typeForTesting(_ text: String) {
        queryField.stringValue = text
        controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: queryField))
    }

    func fieldCommandForTesting(_ selector: Selector) -> Bool {
        control(queryField, textView: NSTextView(), doCommandBy: selector)
    }

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = ChromeMetrics.Radius.control
        FieldChrome.apply(to: self, isFocused: false)

        titleLabel.font = ChromeType.font(.body)
        titleLabel.textColor = Theme.current.chrome.ink(.normal)
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
            titleLeading,
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

    func itemTitles() -> [String] { [] }

    func restingOrder() -> [Int] { Array(itemTitles().indices) }

    func openingHighlight() -> Int { visible.first ?? 0 }

    func itemRows() -> [ListPopover.Row] { [] }

    func renderRows() {}

    func highlightedRow() -> NSView? { nil }

    func pick(_ index: Int) {}

    func listDidClose() {}

    /// Rebuilds an open list too: its rows bake in the theme at build time.
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
        FieldChrome.apply(to: self, isFocused: isFocusedStop || popover.isOpen)
    }

    /// Fallback only: an open list normally holds focus in the query field, whose delegate routes its keys.
    override func keyDown(with event: NSEvent) {
        if popover.isOpen {
            switch KeyboardFocus.key(for: event) {
            case .up: moveHighlight(-1)
            case .down: moveHighlight(1)
            case .activate: pickHighlighted()
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

    /// Closes before taking focus: focusing first would end the field's edit and close the list inside the focus change.
    override func mouseDown(with event: NSEvent) {
        if popover.isOpen {
            closeList()
            window?.makeFirstResponder(self)
        } else {
            window?.makeFirstResponder(self)
            openList()
        }
    }

    /// The label and chevron are controls that would swallow the click, so the whole view takes it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, alphaValue > 0 else { return nil }
        return bounds.contains(convert(point, from: superview)) ? self : nil
    }

    /// Guarded before building rows: a second open would repoint the rows at views in no card.
    private func openList() {
        guard !popover.isOpen, window?.contentView != nil else { return }
        query = ""
        refilter()
        highlighted = openingHighlight()
        popover.open(rows: listRows())
        renderRows()
        revealHighlight()
        beginEditing()
        restyle()
    }

    func closeList() {
        let wasOpen = popover.isOpen
        popover.close()
        guard wasOpen else { return endEditing() }
        finishClosing()
    }

    private func finishClosing() {
        query = ""
        endEditing()
        restyle()
        listDidClose()
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

    /// Stands in for the query field's placeholder while editing: setting a placeholder mid-edit ends the edit.
    private func renderTitle() {
        titleLabel.stringValue = title
        titleLabel.textColor = Theme.current.chrome.ink(isEditing ? .muted : .normal)
        titleLabel.isHidden = isEditing && !query.isEmpty
    }

    private func moveHighlight(_ delta: Int) {
        guard
            let next = KeyboardFocus.step(from: visible.firstIndex(of: highlighted), delta: delta, count: visible.count)
        else { return }
        highlighted = visible[next]
        renderRows()
        revealHighlight()
    }

    private func revealHighlight() {
        guard let row = highlightedRow() else { return }
        popover.reveal(row)
    }

    private func pickHighlighted() {
        guard visible.contains(highlighted) else { return }
        pick(highlighted)
    }

    private func refilter() {
        guard !query.isEmpty else {
            visible = restingOrder()
            return
        }
        let titles = itemTitles()
        visible =
            titles.indices
            .compactMap { index -> (index: Int, score: Int)? in
                guard let score = FuzzyMatch.score(query, titles[index]) else { return nil }
                return (index, score)
            }
            .sorted { $0.score == $1.score ? $0.index < $1.index : $0.score > $1.score }
            .map(\.index)
    }

    private func rebuildOpenList() {
        guard popover.isOpen else { return }
        popover.close()
        popover.open(rows: listRows())
        renderRows()
        revealHighlight()
    }

    /// Skips an unchanged filter: rebuilding the card costs about 22 ms at sixty-five rows.
    private func rerenderList() {
        renderTitle()
        guard popover.isOpen else { return }
        let before = visible
        refilter()
        guard visible != before else { return }
        highlighted = query.isEmpty ? openingHighlight() : visible.first ?? highlighted
        rebuildOpenList()
    }

    private func listRows() -> [ListPopover.Row] {
        let rows = itemRows()
        return visible.isEmpty ? [ListPopover.Row(view: Self.noMatchesRow(), height: Self.rowHeight)] : rows
    }

    private static func noMatchesRow() -> NSView {
        let label = EmptyStateLabel("No matches")
        let host = NSView()
        host.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: ChromeMetrics.Spacing.controlInset),
            label.trailingAnchor.constraint(
                lessThanOrEqualTo: host.trailingAnchor, constant: -ChromeMetrics.Spacing.controlInset),
            label.centerYAnchor.constraint(equalTo: host.centerYAnchor),
        ])
        return host
    }
}

extension PopoverPicker: NSTextFieldDelegate {
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
            pickHighlighted()
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
