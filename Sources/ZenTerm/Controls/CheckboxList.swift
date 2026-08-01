import AppKit

struct CheckboxListItem: Equatable {
    let title: String
    let isChecked: Bool
}

/// A keyboard-navigable vertical checkbox list — the chrome's multi-select control. One focus stop
/// in a form's flow (like `SegmentedControl`): Up/Down move an internal highlight, bubbling to the
/// form at the boundaries; Space/Return toggle the highlighted row; Left exits to the nav; Tab/⇧Tab
/// bubble. Clicking a row toggles it. The control renders state, it doesn't own it: `onToggle`
/// reports the toggled index and the owner re-syncs via `setItems` once the write lands.
final class CheckboxList: NSView {
    private(set) var items: [CheckboxListItem]
    var onToggle: (Int) -> Void
    var onArrowUp: (() -> Void)?
    var onArrowDown: (() -> Void)?
    var onArrowLeft: (() -> Void)?
    var onTab: (() -> Void)?
    var onBacktab: (() -> Void)?

    private var rowViews: [RowView] = []
    private var highlightedIndex = 0
    private var isControlFocused = false

    private static let rowHeight: CGFloat = 24
    private static let rowSpacing: CGFloat = 2

    init(items: [CheckboxListItem], onToggle: @escaping (Int) -> Void) {
        self.items = items
        self.onToggle = onToggle
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        rowViews = items.indices.map { index in
            let row = RowView()
            row.onClick = { [weak self] in self?.toggle(index) }
            return row
        }
        let stack = NSStackView(views: rowViews)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Self.rowSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        for row in rowViews {
            row.heightAnchor.constraint(equalToConstant: Self.rowHeight).isActive = true
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        render()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Programmatic sync after a config reload — never fires `onToggle` (the same rule as
    /// `SegmentedControl.setSelection`). The row count is fixed at init: the list renders a static
    /// catalog whose checked states move, not a variable catalog.
    func setItems(_ items: [CheckboxListItem]) {
        self.items = Array(items.prefix(rowViews.count))
        render()
    }

    var itemsForTesting: [CheckboxListItem] { items }
    var highlightedIndexForTesting: Int { highlightedIndex }
    /// The row views in list order, for click tests that drive a row's real `mouseDown`.
    var rowViewsForTesting: [NSView] { rowViews }

    func reapplyTheme() { render() }

    private func toggle(_ index: Int) {
        guard items.indices.contains(index) else { return }
        highlightedIndex = index
        render()
        onToggle(index)
    }

    private func render() {
        for (index, row) in rowViews.enumerated() {
            guard items.indices.contains(index) else { continue }
            row.render(
                item: items[index],
                isHighlighted: isControlFocused && index == highlightedIndex)
        }
    }

    // MARK: keyboard

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        isControlFocused = true
        render()
        return true
    }

    override func resignFirstResponder() -> Bool {
        isControlFocused = false
        render()
        return true
    }

    override func drawFocusRingMask() {}  // the highlighted row's accent outline marks focus

    override func keyDown(with event: NSEvent) {
        switch KeyboardFocus.key(for: event) {
        case .up where highlightedIndex == 0: onArrowUp?()  // boundary → previous field
        case .up: moveHighlight(-1)
        case .down where highlightedIndex == items.count - 1: onArrowDown?()  // boundary → next field
        case .down: moveHighlight(1)
        case .activate: toggle(highlightedIndex)  // return / enter / space
        case .left: onArrowLeft?()  // a list owns no Left → nav
        case .tab(let shift) where onTab != nil || onBacktab != nil:
            shift ? onBacktab?() : onTab?()
        default: super.keyDown(with: event)
        }
    }

    private func moveHighlight(_ delta: Int) {
        highlightedIndex = min(max(highlightedIndex + delta, 0), items.count - 1)
        render()
    }

    // MARK: row

    /// One checkbox row: a fixed-width check slot (so titles align whether checked or not) and the
    /// title. Checked rows show an accent check and full-strength title; unchecked rows dim the
    /// title so the split reads at a glance. The keyboard highlight is an accent outline.
    private final class RowView: NSView {
        var onClick: (() -> Void)?
        private let check = NSImageView()
        private let title = NSTextField(labelWithString: "")

        init() {
            super.init(frame: .zero)
            wantsLayer = true
            layer?.cornerRadius = 6
            layer?.borderWidth = 1
            translatesAutoresizingMaskIntoConstraints = false

            check.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
            check.translatesAutoresizingMaskIntoConstraints = false
            title.font = .systemFont(ofSize: 13)
            title.translatesAutoresizingMaskIntoConstraints = false
            addSubview(check)
            addSubview(title)
            NSLayoutConstraint.activate([
                check.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
                check.widthAnchor.constraint(equalToConstant: 14),
                check.centerYAnchor.constraint(equalTo: centerYAnchor),
                title.leadingAnchor.constraint(equalTo: check.trailingAnchor, constant: 6),
                title.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
                title.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        func render(item: CheckboxListItem, isHighlighted: Bool) {
            let chrome = Theme.current.chrome
            title.stringValue = item.title
            title.textColor = item.isChecked ? chrome.foreground.nsColor : chrome.ink(alpha: 0.5)
            check.isHidden = !item.isChecked
            check.contentTintColor = chrome.accent.nsColor
            layer?.backgroundColor =
                isHighlighted ? chrome.ink(alpha: 0.10).cgColor : NSColor.clear.cgColor
            layer?.borderColor = (isHighlighted ? chrome.accent.nsColor : .clear).cgColor
        }

        override func mouseDown(with event: NSEvent) { onClick?() }
    }
}
