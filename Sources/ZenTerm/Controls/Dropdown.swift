import AppKit

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
    private let chevron = NSImageView()
    private let swatch = NSView()
    private var titleAfterSwatch = NSLayoutConstraint()
    private var titleAtLeading = NSLayoutConstraint()
    private lazy var popover: ListPopover = {
        let popover = ListPopover(anchor: self)
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
    private let queryField = NSTextField()
    private var isEditing = false
    private var query = ""
    private var visible: [Int] = []
    private var isFocusedStop = false

    static let swatchSize: CGFloat = 10
    private static let rowHeight: CGFloat = 28
    private static let headerHeight: CGFloat = 20

    var buttonTitleForTesting: String { titleLabel.stringValue }
    var itemsForTesting: [DropdownItem] { items }

    func openListForTesting() { openList() }
    var listCardSizeForTesting: NSSize { popover.cardFrame.size }
    var listCardFrameForTesting: NSRect { popover.cardFrame }
    func moveHighlightForTesting(_ delta: Int) { moveHighlight(delta) }
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
        layer?.borderColor = Theme.current.chrome.fill(alpha: ChromeTheme.border).cgColor

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
        swatch.layer?.borderColor = Theme.current.chrome.fill(alpha: ChromeTheme.swatchRing).cgColor
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

    var titlePrefix: String = "" { didSet { renderTitle() } }

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
        swatch.layer?.backgroundColor = item?.swatch?.cgColor
        swatch.isHidden = item?.swatch == nil
        titleAfterSwatch.isActive = false
        titleAtLeading.isActive = false
        (swatch.isHidden ? titleAtLeading : titleAfterSwatch).isActive = true
    }

    /// Rebuilds an open list too: its rows bake in the theme at build time.
    func reapplyTheme() {
        restyle()
        titleLabel.textColor = Theme.current.chrome.foreground.nsColor
        chevron.contentTintColor = Theme.current.chrome.ink(.muted)
        swatch.layer?.borderColor = Theme.current.chrome.fill(alpha: ChromeTheme.swatchRing).cgColor
        queryField.textColor = Theme.current.chrome.foreground.nsColor
        if !queryField.isHidden {
            renderQueryPlaceholder()
            queryField.applyThemedCaret()
        }
        rebuildOpenList()
    }

    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool {
        isFocusedStop = true
        restyle()
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

    /// The card is parented to the content view, so it has to close when the dropdown leaves the window.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { closeList() }
    }

    private func restyle() {
        PopoverButtonStyle.apply(to: self, isFocused: isFocusedStop, isOpen: popover.isOpen)
    }

    /// Fallback only: an open list normally holds focus in the query field, whose delegate routes its keys.
    override func keyDown(with event: NSEvent) {
        if popover.isOpen {
            switch KeyboardFocus.key(for: event) {
            case .up: moveHighlight(-1)
            case .down: moveHighlight(1)
            case .activate: commitHighlight()
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

    private func escapePressed() {
        if query.isEmpty {
            closeList()
        } else {
            query = ""
            queryField.stringValue = ""
            rerenderList()
        }
    }

    func typeForTesting(_ text: String) {
        queryField.stringValue = text
        controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: queryField))
    }

    var isEditingForTesting: Bool { !queryField.isHidden }

    func fieldCommandForTesting(_ selector: Selector) -> Bool {
        control(queryField, textView: NSTextView(), doCommandBy: selector)
    }

    var queryFieldTextColorForTesting: NSColor? { queryField.textColor }

    var rowFillsForTesting: [NSColor?] {
        rowViews.map { $0.layer?.backgroundColor.flatMap(NSColor.init(cgColor:)) }
    }

    var queryForTesting: String { query }

    var visibleIndicesForTesting: [Int] { visible }

    var isPopoverOpen: Bool { popover.isOpen }

    /// Reads `isOpen` before taking focus: focusing ends the field's editing, which closes the list synchronously.
    override func mouseDown(with event: NSEvent) {
        let wasOpen = popover.isOpen
        window?.makeFirstResponder(self)
        if wasOpen { closeList() } else { openList() }
    }

    /// The label and chevron are controls that would swallow the click, so the whole view takes it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, alphaValue > 0 else { return nil }
        return bounds.contains(convert(point, from: superview)) ? self : nil
    }

    /// Guarded before `buildRows()`: a second open would repoint `rowViews` at views in no card.
    private func openList() {
        guard !popover.isOpen, window?.contentView != nil else { return }
        query = ""
        refilter()
        highlighted = selectedIndex
        beginEditing()
        popover.open(rows: buildRows())
        refreshListHighlight()
        scrollHighlightIntoView()
        restyle()
    }

    private func closeList() {
        popover.close()
        query = ""
        endEditing()
        rowViews = []
        restyle()
    }

    private func beginEditing() {
        queryField.stringValue = ""
        renderQueryPlaceholder()
        titleLabel.isHidden = true
        queryField.isHidden = false
        isEditing = true
        window?.makeFirstResponder(queryField)
        queryField.applyThemedCaret()
    }

    /// Restores focus before hiding the field: hiding a first responder dumps focus to the window.
    private func endEditing() {
        let wasEditing = isEditing
        isEditing = false
        if wasEditing { window?.makeFirstResponder(self) }
        queryField.isHidden = true
        titleLabel.isHidden = false
    }

    /// `placeholderString` draws in `placeholderTextColor`, which follows `effectiveAppearance`, not `Theme.current`.
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

    private func scrollHighlightIntoView() {
        guard let row = rowViews.first(where: { $0.index == highlighted }) else { return }
        row.scrollToVisible(row.bounds)
    }

    private func commitHighlight() {
        guard visible.contains(highlighted) else { return }
        selectedIndex = highlighted
        renderTitle()
        closeList()
        onChange(selectedIndex)
        window?.makeFirstResponder(self)
    }

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
            .sorted { $0.score == $1.score ? $0.index < $1.index : $0.score > $1.score }
            .map(\.index)
    }

    private func rebuildOpenList() {
        guard popover.isOpen else { return }
        popover.close()
        popover.open(rows: buildRows())
        refreshListHighlight()
        scrollHighlightIntoView()
    }

    /// Skips an unchanged filter: rebuilding the card costs about 22 ms at sixty-five rows.
    private func rerenderList() {
        guard popover.isOpen else { return }
        let before = visible
        refilter()
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
            dot.layer?.borderWidth = 1
            dot.layer?.borderColor = chrome.fill(alpha: ChromeTheme.swatchRing).cgColor
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
        layer?.backgroundColor = (isHighlighted ? chrome.fill(.hover) : NSColor.clear).cgColor
    }
}

extension Dropdown: NSTextFieldDelegate {
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
            commitHighlight()
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
