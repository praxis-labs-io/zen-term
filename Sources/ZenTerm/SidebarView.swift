import AppKit

enum SidebarRowID: Hashable {
    case workspace(WorkspaceID)
    case ghost(String)
}

struct SidebarRowItem: Equatable {
    let id: SidebarRowID
    let variant: SettingsNavRow.Variant
    let name: String
    let branch: String?
    let number: Int?
    let isActive: Bool
    let makesWorktrees: Bool
}

final class SidebarView: NSView {
    static let width: CGFloat = 240
    private static let padding: CGFloat = 8
    private static let captionHeight: CGFloat = 28
    private static let captionInset: CGFloat = 10
    private static let addInset: CGFloat = 4
    private static let newWorktreeSize = NSSize(width: 20, height: 20)

    private let caption = FieldCaption("Workspaces", required: false)
    private let addButton: IconButton
    private let rowStack = NSStackView()
    private var rows: [SidebarRowID: SettingsNavRow] = [:]
    private var numbers: [SidebarRowID: Int] = [:]
    private var worktreeParents: Set<WorkspaceID> = []
    let rowMenu = SidebarRowMenu()
    var onLeave: (() -> Void)?
    private let onActivate: (SidebarRowID) -> Void
    private let onNewWorktree: (WorkspaceID) -> Void

    init(
        onActivate: @escaping (SidebarRowID) -> Void, onNewWorktree: @escaping (WorkspaceID) -> Void,
        onAdd: @escaping () -> Void
    ) {
        self.onActivate = onActivate
        self.onNewWorktree = onNewWorktree
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
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        var removedFocusedRow = false
        for (id, row) in rows where byID[id]?.variant != row.variant {
            removedFocusedRow = removedFocusedRow || KeyboardFocus.isFocused(row, in: window)
            if rowMenu.anchor === row { rowMenu.close() }
            row.removeFromSuperview()
            rows[id] = nil
        }
        numbers = byID.compactMapValues(\.number)
        worktreeParents = Set(
            items.compactMap {
                guard $0.makesWorktrees, case .workspace(let id) = $0.id else { return nil }
                return id
            })
        for (index, item) in items.enumerated() {
            let row = self.row(for: item)
            if rowStack.arrangedSubviews.firstIndex(of: row) != index {
                let isNew = row.superview == nil
                if !isNew { rowStack.removeArrangedSubview(row) }
                rowStack.insertArrangedSubview(row, at: index)
                if isNew { row.widthAnchor.constraint(equalTo: rowStack.widthAnchor).isActive = true }
            }
            row.setTitle(item.name)
            row.setDetail(item.branch)
            row.setSelected(item.isActive)
            setNewWorktreeButton(on: row, for: item)
        }
        if removedFocusedRow { onLeave?() }
    }

    private func row(for item: SidebarRowItem) -> SettingsNavRow {
        if let row = rows[item.id] { return row }
        let id = item.id
        let row = SettingsNavRow(title: item.name, variant: item.variant, focusesOnClick: false) {
            [weak self] in self?.onActivate(id)
        }
        if case .workspace = id {
            row.tooltip = TooltipHost(label: "Switch workspace") { [weak self] in
                guard let number = self?.numbers[id], number <= 9 else { return nil }
                return CommandCatalog.spec(for: .selectWorkspace(number)).shortcut
            }
        }
        row.onArrowUp = { [weak self] in self?.moveFocus(-1) }
        row.onArrowDown = { [weak self] in self?.moveFocus(1) }
        row.onReturn = { [weak self] in self?.onActivate(id) }
        row.onEscape = { [weak self] in self?.onLeave?() }
        row.onSecondaryClick = { [weak self, weak row] in
            guard let self, let row else { return }
            self.rowMenu.open(self.menuItems(for: id), from: row)
        }
        rows[item.id] = row
        return row
    }

    private func setNewWorktreeButton(on row: SettingsNavRow, for item: SidebarRowItem) {
        guard item.makesWorktrees, case .workspace(let id) = item.id else { return row.setHoverAccessory(nil) }
        guard row.hoverAccessory == nil else { return }
        row.setHoverAccessory(
            IconButton(
                symbol: "plus", size: Self.newWorktreeSize, pointSize: 11, accessibilityLabel: "New worktree",
                shortcut: { CommandCatalog.spec(for: .createWorktree).shortcut }
            ) { [weak self] in self?.onNewWorktree(id) })
    }

    private func menuItems(for row: SidebarRowID) -> [SidebarRowMenu.Item] {
        guard case .workspace(let id) = row, worktreeParents.contains(id) else { return [] }
        return [
            SidebarRowMenu.Item(title: "New Worktree…", action: .createWorktree) { [weak self] in
                self?.onNewWorktree(id)
            }
        ]
    }

    override func viewDidHide() {
        super.viewDidHide()
        rowMenu.close()
    }

    var hasFocus: Bool { focusedRow != nil }

    var focusedRow: SidebarRowID? { rows.first { KeyboardFocus.isFocused($0.value, in: window) }?.key }

    func focusRow(_ id: SidebarRowID) {
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
        rowMenu.close()
        caption.reapplyTheme()
        addButton.reapplyTheme()
        for row in rows.values {
            row.reapplyTheme()
            (row.hoverAccessory as? IconButton)?.reapplyTheme()
        }
    }

    var addButtonForTesting: IconButton { addButton }

    var rowsForTesting: [SettingsNavRow] { orderedRows }
}
