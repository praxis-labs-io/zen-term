import AppKit

/// A `ListPopover`, not a `Dropdown`, so the text field keeps first responder while the list is up.
final class BranchField: NSView, ThemeReapplying {
    let box = FieldBox(placeholder: "feature/name")
    var field: NSTextField { box.field }

    var onChange: (() -> Void)?
    var onArrowUp: (() -> Void)?
    var onArrowDown: (() -> Void)?
    var onTab: (() -> Void)?
    var onBacktab: (() -> Void)?
    var onEnter: (() -> Void)?
    var onSubmit: (() -> Void)?

    private var branches: [String] = []
    private var notes: [String: String] = [:]
    private var matches: [String] = []
    private var highlighted = 0
    private lazy var popover = ListPopover(anchor: box)
    private var rowViews: [ListRow] = []

    private static let rowHeight: CGFloat = ChromeMetrics.Height.control

    var text: String { box.text }
    var isListOpen: Bool { popover.isOpen }

    #if DEBUG
        var matchesForTesting: [String] { matches }
        func listFilterForTesting(_ event: NSEvent) -> NSEvent? { popover.filterForTesting(event) }
        var highlightedForTesting: String? {
            matches.indices.contains(highlighted) ? matches[highlighted] : nil
        }
    #endif

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(box)
        NSLayoutConstraint.activate([
            box.leadingAnchor.constraint(equalTo: leadingAnchor),
            box.trailingAnchor.constraint(equalTo: trailingAnchor),
            box.topAnchor.constraint(equalTo: topAnchor),
            box.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        box.onChange = { [weak self] in
            self?.refreshMatches()
            self?.onChange?()
        }
        box.onArrowUp = { [weak self] in self?.arrow(-1) }
        box.onArrowDown = { [weak self] in self?.arrow(1) }
        box.onTab = { [weak self] in
            self?.closeList()
            self?.onTab?()
        }
        box.onBacktab = { [weak self] in
            self?.closeList()
            self?.onBacktab?()
        }
        box.onEnter = { [weak self] in self?.enter() }
        box.onSubmit = { [weak self] in
            self?.closeList()
            self?.onSubmit?()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { closeList() }
    }

    func setBranches(_ branches: Set<String>, notes: [String: String]) {
        self.branches = branches.sorted()
        self.notes = notes
    }

    func setText(_ value: String) {
        box.setText(value)
        closeList()
    }

    func repositionList() {
        guard popover.isOpen else { return }
        popover.reposition()
    }

    func closeList() {
        guard popover.isOpen else { return }
        popover.close()
        rowViews = []
    }

    private func arrow(_ delta: Int) {
        guard popover.isOpen else {
            if delta > 0 {
                matches = suggestions(for: text)
                highlighted = 0
                if !matches.isEmpty {
                    openList()
                    return
                }
            }
            (delta < 0 ? onArrowUp : onArrowDown)?()
            return
        }
        guard let next = KeyboardFocus.step(from: highlighted, delta: delta, count: matches.count) else { return }
        highlighted = next
        renderRows()
    }

    private func highlightPointed(_ index: Int) {
        guard popover.isOpen, index != highlighted, rowViews.indices.contains(index) else { return }
        highlighted = index
        for (position, row) in rowViews.enumerated() { row.isHighlighted = position == index }
    }

    private func enter() {
        guard popover.isOpen, matches.indices.contains(highlighted) else {
            onEnter?()
            return
        }
        commit(matches[highlighted])
    }

    private func commit(_ branch: String) {
        box.setText(branch)
        closeList()
        matches = []
        onChange?()
    }

    private func refreshMatches() {
        matches = suggestions(for: text)
        guard !matches.isEmpty else {
            closeList()
            return
        }
        highlighted = 0
        if popover.isOpen { rerenderList() } else { openList() }
    }

    private func suggestions(for query: String) -> [String] {
        let ranked = ranked(for: query)
        return ranked == [query] ? [] : ranked
    }

    private func ranked(for query: String) -> [String] {
        guard !query.isEmpty else { return branches }
        let scored = branches.compactMap { branch -> (String, Int)? in
            guard let score = FuzzyMatch.score(query, branch) else { return nil }
            return (branch, branch == query ? Int.max : score)
        }
        return scored.sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }.map(\.0)
    }

    private func openList() {
        popover.onSelfClose = { [weak self] in self?.rowViews = [] }
        popover.open(rows: buildRows())
        renderRows()
    }

    private func rerenderList() {
        popover.replace(rows: buildRows())
        renderRows()
    }

    private func buildRows() -> [ListPopover.Row] {
        rowViews = matches.enumerated().map { index, branch in
            let content = ListRow.Content(title: branch, note: notes[branch], leading: .symbol("arrow.branch"))
            let row = ListRow(content) { [weak self] in self?.commit(branch) }
            row.onPointerEnter = { [weak self] in self?.highlightPointed(index) }
            return row
        }
        return rowViews.map { ListPopover.Row(view: $0, height: Self.rowHeight) }
    }

    private func renderRows() {
        if rowViews.indices.contains(highlighted) { popover.reveal(rowViews[highlighted]) }
        for (index, row) in rowViews.enumerated() { row.isHighlighted = index == highlighted }
    }

    func reapplyTheme() {
        guard popover.isOpen else { return }
        rerenderList()
    }
}
