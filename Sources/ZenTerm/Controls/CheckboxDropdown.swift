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
    private let chevron = NSImageView()
    /// A window resize closes the card without `closeList`, so the self-close hook repeats that cleanup.
    private lazy var popover: ListPopover = {
        let popover = ListPopover(anchor: self)
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
    private var visible: [Int] = []
    private var query = ""
    private var highlighted = 0
    var restingIndices: [Int]?
    private var isFocusedStop = false

    private static let rowHeight: CGFloat = 28

    var buttonTitleForTesting: String { titleLabel.stringValue }
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
    }

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

    /// The open card lives on the window's content view, so it would outlive a torn-out ancestor.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { closeList() }
    }

    private func restyle() {
        PopoverButtonStyle.apply(to: self, isFocused: isFocusedStop, isOpen: popover.isOpen)
    }

    override func keyDown(with event: NSEvent) {
        if popover.isOpen {
            switch KeyboardFocus.key(for: event) {
            case .up: moveHighlight(-1)
            case .down: moveHighlight(1)
            case .activate: toggleHighlight()
            case .escape: escapePressed()
            case .delete: backspace()
            default: typed(event)
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
        window?.makeFirstResponder(self)
        popover.isOpen ? closeList() : openList()
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

    private func typed(_ event: NSEvent) {
        guard event.modifierFlags.isDisjoint(with: [.command, .control, .option]),
            let characters = event.charactersIgnoringModifiers, !characters.isEmpty,
            characters.unicodeScalars.allSatisfy(Self.isTypable)
        else { return }
        query += characters
        rerenderList()
    }

    /// AppKit encodes Home, End, the page keys and F-keys as private-use scalars `Character` calls printable.
    private static func isTypable(_ scalar: Unicode.Scalar) -> Bool {
        !CharacterSet.whitespacesAndNewlines.contains(scalar)
            && !CharacterSet.controlCharacters.contains(scalar)
            && !(0xF700...0xF8FF).contains(scalar.value)
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

    private func rerenderList() {
        renderTitle()
        guard popover.isOpen else { return }
        let before = visible
        refilter()
        guard visible != before else { return }
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
