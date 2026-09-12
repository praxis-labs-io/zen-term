import AppKit

/// A branch name field that suggests the repo's existing branches as you type. Typing a name that
/// exists picks that branch; typing a new one cuts it.
///
/// A `ListPopover` rather than a `Dropdown`: the text field has to keep first responder while the
/// list advises it, and a `Dropdown` is a closed select that takes the keyboard for itself.
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
    private var holders: [String: WorktreeStore.Holder] = [:]
    /// Indices into `branches`, in the order the list shows them.
    private var matches: [String] = []
    private var highlighted = 0
    private lazy var popover = ListPopover(anchor: box)
    private var rowViews: [BranchRowView] = []

    private static let rowHeight: CGFloat = 26

    var text: String { box.text }
    var isListOpen: Bool { popover.isOpen }

    #if DEBUG
        var matchesForTesting: [String] { matches }
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
        box.onEndEditing = { [weak self] in self?.closeList() }
        // The list owns Esc only while it is up. The card root gets every other one.
        box.onEscape = { [weak self] in
            guard let self, self.isListOpen else { return false }
            self.closeList()
            return true
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The list is parented to the window's content view, so nothing takes it down with this view.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { closeList() }
    }

    func setBranches(_ branches: Set<String>, holders: [String: WorktreeStore.Holder]) {
        self.branches = branches.sorted()
        self.holders = holders
    }

    func setText(_ value: String) {
        box.setText(value)
        closeList()
    }

    /// Where `text` is checked out, when it names a branch something already holds.
    var holderOfTypedBranch: WorktreeStore.Holder? { holders[text] }

    /// Put an open list back against the field. The popover is frame-placed once, so anything that
    /// moves the field on screen has to say so.
    func repositionList() {
        guard popover.isOpen else { return }
        popover.reposition()
    }

    func closeList() {
        guard popover.isOpen else { return }
        popover.close()
        rowViews = []
    }

    // MARK: keyboard

    /// Down opens the list when there is one to open, so an empty field still reaches the branches.
    private func arrow(_ delta: Int) {
        guard popover.isOpen else {
            // Ranked here rather than read: an untouched field has never filtered, and Down on an
            // empty one is how the whole branch list is reached.
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
        guard !matches.isEmpty else { return }
        highlighted = (highlighted + delta + matches.count) % matches.count
        renderRows()
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

    // MARK: the list

    private func refreshMatches() {
        matches = suggestions(for: text)
        guard !matches.isEmpty else {
            closeList()
            return
        }
        highlighted = 0
        if popover.isOpen { rerenderList() } else { openList() }
    }

    /// What the list should show for `query`. Empty when there is nothing worth showing: nothing
    /// matches, which would render as a bare sliver, or the query is already the only match, where
    /// the choice is made and a one-row list restating it would trap Down inside itself.
    private func suggestions(for query: String) -> [String] {
        let ranked = ranked(for: query)
        return ranked == [query] ? [] : ranked
    }

    /// An exact match leads, then `FuzzyMatch` order, then the alphabetical listing as the
    /// tiebreak so the same query never reorders between two runs.
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
        closeList()
        openList()
    }

    private func buildRows() -> [ListPopover.Row] {
        rowViews = matches.map { branch in
            BranchRowView(onClick: { [weak self] in self?.commit(branch) })
        }
        return rowViews.map { ListPopover.Row(view: $0, height: Self.rowHeight) }
    }

    private func renderRows() {
        let chrome = Theme.current.chrome
        // The list caps at 260pt, so past nine branches the highlight walks off the bottom and
        // Return commits one the user cannot see. `Dropdown` and `CheckboxDropdown` do the same.
        if rowViews.indices.contains(highlighted) {
            let row = rowViews[highlighted]
            row.scrollToVisible(row.bounds)
        }
        for (index, row) in rowViews.enumerated() {
            let branch = matches[index]
            row.render(
                branch: branch, note: Self.note(for: holders[branch]),
                isHighlighted: index == highlighted, chrome: chrome)
        }
    }

    /// Held branches keep their row: hiding one leaves the user typing the name by hand and
    /// meeting the refusal with no explanation.
    private static func note(for holder: WorktreeStore.Holder?) -> String? {
        switch holder {
        case .worktree: return "has a worktree"
        case .mainCheckout: return "main checkout"
        case nil: return nil
        }
    }

    func reapplyTheme() {
        box.reapplyTheme()
        guard popover.isOpen else { return }
        rerenderList()
    }

    /// One branch in the open list: the ref icon, the name, and where it is checked out.
    private final class BranchRowView: NSView {
        private let onClick: () -> Void
        private let icon = NSImageView()
        private let title = NSTextField(labelWithString: "")
        private let note = NSTextField(labelWithString: "")

        init(onClick: @escaping () -> Void) {
            self.onClick = onClick
            super.init(frame: .zero)
            wantsLayer = true
            layer?.cornerRadius = 5
            translatesAutoresizingMaskIntoConstraints = false

            icon.image = NSImage(systemSymbolName: "arrow.branch", accessibilityDescription: nil)
            icon.symbolConfiguration = .init(pointSize: 11, weight: .regular)
            icon.translatesAutoresizingMaskIntoConstraints = false
            title.font = .systemFont(ofSize: 13)
            title.lineBreakMode = .byTruncatingTail
            title.translatesAutoresizingMaskIntoConstraints = false
            note.font = .systemFont(ofSize: 11)
            note.translatesAutoresizingMaskIntoConstraints = false
            note.setContentCompressionResistancePriority(.required, for: .horizontal)
            addSubview(icon)
            addSubview(title)
            addSubview(note)
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
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

        func render(branch: String, note text: String?, isHighlighted: Bool, chrome: ChromeTheme) {
            title.stringValue = branch
            title.textColor = chrome.foreground.nsColor
            note.stringValue = text ?? ""
            note.textColor = chrome.ink(.faint)
            note.isHidden = text == nil
            icon.contentTintColor = chrome.ink(.subtle)
            layer?.backgroundColor = (isHighlighted ? chrome.fill(.hover) : NSColor.clear).cgColor
        }

        override func mouseDown(with event: NSEvent) { onClick() }
    }
}
