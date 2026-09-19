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
    private static let sectionGap: CGFloat = 14
    private static let agentsBottomGap: CGFloat = 8

    private let caption = FieldCaption("Workspaces", required: false)
    private let addButton: IconButton
    private let rowStack = NSStackView()
    private var rows: [WorkspaceID: SettingsNavRow] = [:]
    private let agentsCaption = FieldCaption("Agents", required: false)
    private let agentScroll = NSScrollView()
    private let agentStack = NSStackView()
    private var agentRows: [SurfaceID: SidebarAgentRow] = [:]
    var onLeave: (() -> Void)?
    var onJump: ((SurfaceID) -> Void)?
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
        installAgents()

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

    private func installAgents() {
        agentStack.orientation = .vertical
        agentStack.alignment = .leading
        agentStack.spacing = 0
        agentStack.translatesAutoresizingMaskIntoConstraints = false
        let clip = FlippedClipView()
        clip.drawsBackground = false
        agentScroll.contentView = clip
        agentScroll.documentView = agentStack
        agentScroll.drawsBackground = false
        agentScroll.hasVerticalScroller = true
        agentScroll.autohidesScrollers = true
        agentScroll.scrollerStyle = .overlay
        agentScroll.translatesAutoresizingMaskIntoConstraints = false
        agentsCaption.translatesAutoresizingMaskIntoConstraints = false
        addSubview(agentsCaption)
        addSubview(agentScroll)
        let fitsContent = agentScroll.heightAnchor.constraint(equalTo: agentStack.heightAnchor)
        fitsContent.priority = .defaultHigh - 1
        NSLayoutConstraint.activate([
            agentsCaption.leadingAnchor.constraint(equalTo: caption.leadingAnchor),
            agentsCaption.centerYAnchor.constraint(
                equalTo: rowStack.bottomAnchor, constant: Self.sectionGap + Self.captionHeight / 2),
            agentScroll.topAnchor.constraint(
                equalTo: rowStack.bottomAnchor, constant: Self.sectionGap + Self.captionHeight),
            agentScroll.leadingAnchor.constraint(equalTo: rowStack.leadingAnchor),
            agentScroll.trailingAnchor.constraint(equalTo: rowStack.trailingAnchor),
            agentStack.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            agentStack.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            agentStack.topAnchor.constraint(equalTo: clip.topAnchor),
            fitsContent,
        ])
        setAgentsHidden(true)
    }

    func limitAgents(above anchor: NSLayoutYAxisAnchor) {
        agentScroll.bottomAnchor.constraint(lessThanOrEqualTo: anchor, constant: -Self.agentsBottomGap).isActive = true
    }

    private func setAgentsHidden(_ hidden: Bool) {
        agentsCaption.isHidden = hidden
        agentScroll.isHidden = hidden
    }

    func renderAgents(_ items: [SidebarAgentItem]) {
        let ids = Set(items.map(\.id))
        var removedFocusedRow = false
        for (id, row) in agentRows where !ids.contains(id) {
            removedFocusedRow = removedFocusedRow || KeyboardFocus.isFocused(row, in: window)
            row.removeFromSuperview()
            agentRows[id] = nil
        }
        for (index, item) in items.enumerated() {
            let row = agentRow(for: item.id)
            if agentStack.arrangedSubviews.firstIndex(of: row) != index {
                let isNew = row.superview == nil
                if !isNew { agentStack.removeArrangedSubview(row) }
                agentStack.insertArrangedSubview(row, at: index)
                if isNew { row.widthAnchor.constraint(equalTo: agentStack.widthAnchor).isActive = true }
            }
            row.render(item)
        }
        setAgentsHidden(items.isEmpty)
        if removedFocusedRow { onLeave?() }
    }

    private func agentRow(for id: SurfaceID) -> SidebarAgentRow {
        if let row = agentRows[id] { return row }
        let row = SidebarAgentRow { [weak self] in self?.onJump?(id) }
        row.onArrowUp = { [weak self] in self?.moveFocus(-1) }
        row.onArrowDown = { [weak self] in self?.moveFocus(1) }
        row.onEscape = { [weak self] in self?.onLeave?() }
        agentRows[id] = row
        return row
    }

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

    var hasFocus: Bool { focusStops.contains { KeyboardFocus.isFocused($0, in: window) } }

    func focusRow(_ id: WorkspaceID) {
        rows[id]?.takeKeyboardFocus()
    }

    private func moveFocus(_ delta: Int) {
        let stops = focusStops
        let current = stops.firstIndex { KeyboardFocus.isFocused($0, in: window) }
        guard let next = KeyboardFocus.step(from: current, delta: delta, count: stops.count) else { return }
        switch stops[next] {
        case let row as SettingsNavRow: row.takeKeyboardFocus()
        case let row as SidebarAgentRow:
            row.takeKeyboardFocus()
            row.scrollToVisible(row.bounds)
        default: break
        }
    }

    private var focusStops: [NSView] { orderedRows + orderedAgentRows }

    private var orderedAgentRows: [SidebarAgentRow] {
        agentStack.arrangedSubviews.compactMap { $0 as? SidebarAgentRow }
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
        agentsCaption.reapplyTheme()
        for row in rows.values { row.reapplyTheme() }
        for row in agentRows.values { row.reapplyTheme() }
    }

    var addButtonForTesting: IconButton { addButton }

    var rowsForTesting: [SettingsNavRow] { orderedRows }

    var agentRowsForTesting: [SidebarAgentRow] { orderedAgentRows }

    var agentsAreHiddenForTesting: Bool { agentScroll.isHidden && agentsCaption.isHidden }
}
