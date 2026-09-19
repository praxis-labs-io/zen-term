import AppKit

struct SidebarRowItem: Equatable {
    let id: WorkspaceID
    let name: String
    let branch: String?
    let isActive: Bool
}

final class SidebarView: NSView {
    static let width: CGFloat = 240
    private static let padding: CGFloat = 8
    private static let captionHeight: CGFloat = 28
    private static let captionInset: CGFloat = 10
    private static let addInset: CGFloat = 4

    private let caption = FieldCaption("Workspaces", required: false)
    private let addButton: IconButton
    private let rowStack = NSStackView()
    private var rows: [WorkspaceID: SettingsNavRow] = [:]
    var onLeave: (() -> Void)?
    private let onActivate: (WorkspaceID) -> Void

    init(onActivate: @escaping (WorkspaceID) -> Void, onAdd: @escaping () -> Void) {
        self.onActivate = onActivate
        addButton = SidebarFooter.button("plus", "Open workspace", .toggleRepoPicker, onAdd)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        rowStack.orientation = .vertical
        rowStack.alignment = .leading
        rowStack.spacing = 0
        rowStack.translatesAutoresizingMaskIntoConstraints = false
        for view in [caption, addButton, rowStack] { addSubview(view) }

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.width),
            caption.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.padding + Self.captionInset),
            caption.centerYAnchor.constraint(equalTo: topAnchor, constant: Self.captionHeight / 2),
            addButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -(Self.padding + Self.addInset)),
            addButton.centerYAnchor.constraint(equalTo: caption.centerYAnchor),
            rowStack.topAnchor.constraint(equalTo: topAnchor, constant: Self.captionHeight),
            rowStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.padding),
            rowStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.padding),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func render(_ items: [SidebarRowItem]) {
        let ids = Set(items.map(\.id))
        var removedFocusedRow = false
        for (id, row) in rows where !ids.contains(id) {
            removedFocusedRow = removedFocusedRow || KeyboardFocus.isFocused(row, in: window)
            row.removeFromSuperview()
            rows[id] = nil
        }
        for (index, item) in items.enumerated() {
            let row = self.row(for: item)
            if rowStack.arrangedSubviews.firstIndex(of: row) != index {
                let isNew = row.superview == nil
                if !isNew { rowStack.removeArrangedSubview(row) }
                rowStack.insertArrangedSubview(row, at: index)
                if isNew { row.widthAnchor.constraint(equalTo: rowStack.widthAnchor).isActive = true }
            }
            row.setDetail(item.branch)
            row.setSelected(item.isActive)
        }
        if removedFocusedRow { onLeave?() }
    }

    private func row(for item: SidebarRowItem) -> SettingsNavRow {
        if let row = rows[item.id] { return row }
        let id = item.id
        let row = SettingsNavRow(title: item.name, focusesOnClick: false) { [weak self] in self?.onActivate(id) }
        row.tooltip = TooltipHost(label: "Switch workspace") { [weak self, weak row] in
            guard let self, let row, let index = self.rowStack.arrangedSubviews.firstIndex(of: row), index < 9
            else { return nil }
            return CommandCatalog.spec(for: .selectWorkspace(index + 1)).shortcut
        }
        row.onArrowUp = { [weak self] in self?.moveFocus(-1) }
        row.onArrowDown = { [weak self] in self?.moveFocus(1) }
        row.onReturn = { [weak self] in self?.onActivate(id) }
        row.onEscape = { [weak self] in self?.onLeave?() }
        rows[item.id] = row
        return row
    }

    var hasFocus: Bool { rows.values.contains { KeyboardFocus.isFocused($0, in: window) } }

    func focusRow(_ id: WorkspaceID) {
        rows[id]?.takeKeyboardFocus()
    }

    private func moveFocus(_ delta: Int) {
        let ordered = orderedRows
        let current = ordered.firstIndex { KeyboardFocus.isFocused($0, in: window) }
        guard let next = KeyboardFocus.step(from: current, delta: delta, count: ordered.count) else { return }
        ordered[next].takeKeyboardFocus()
    }

    override func keyDown(with event: NSEvent) {
        switch KeyboardFocus.key(for: event) {
        case .left, .right, .tab: return
        default: super.keyDown(with: event)
        }
    }

    private var orderedRows: [SettingsNavRow] {
        rowStack.arrangedSubviews.compactMap { $0 as? SettingsNavRow }
    }

    func reapplyTheme() {
        caption.reapplyTheme()
        addButton.reapplyTheme()
        for row in rows.values { row.reapplyTheme() }
    }

    var addButtonForTesting: IconButton { addButton }

    var rowsForTesting: [SettingsNavRow] { orderedRows }
}
