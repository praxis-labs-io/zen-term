import AppKit

enum SidebarRowID: Hashable {
    case workspace(WorkspaceID)
    case ghost(String)
}

enum SidebarFocusStop: Equatable {
    case row(SidebarRowID)
    case agent(SurfaceID)
    case waitingElsewhere
}

struct SidebarRowItem: Equatable {
    let id: SidebarRowID
    let variant: SettingsNavRow.Variant
    let name: String
    let detail: String?
    let number: Int?
    let isActive: Bool
    let makesWorktrees: Bool
    let isWaiting: Bool
}

final class SidebarView: NSView {
    static let width: CGFloat = 240
    static let padding: CGFloat = 8
    private static let captionHeight: CGFloat = 28
    private static let captionInset: CGFloat = 10
    private static let addInset: CGFloat = 4
    private static let newWorktreeSize = NSSize(width: 20, height: 20)
    private static let sectionGap: CGFloat = 14
    private static let contentBottomGap: CGFloat = 8

    private let caption = FieldCaption("Workspaces", required: false)
    private let addButton: IconButton
    private let rowStack = NSStackView()
    private var rows: [SidebarRowID: SettingsNavRow] = [:]
    private var numbers: [SidebarRowID: Int] = [:]
    private var worktreeParents: Set<SidebarRowID> = []
    private var activeRow: SidebarRowID?
    private var hoverCovers = 0
    private weak var hoverExempt: NSView?
    let rowMenu = SidebarRowMenu()
    private let agentsCaption = FieldCaption("Agents", required: false)
    private let agentStack = NSStackView()
    private let scroll = FadingScrollView()
    private let content = FlippedView()
    private var contentEndsAtRows: NSLayoutConstraint?
    private var contentEndsAtAgents: NSLayoutConstraint?
    private var agentRows: [SurfaceID: SidebarAgentRow] = [:]
    private var waitingRow: SidebarWaitingElsewhereRow?
    private var agentViews: [SidebarAgentRow] = []
    private var waitingElsewhere = (agents: 0, windows: 0, index: 0)
    var onHoverCoverChanged: ((Bool) -> Void)?
    var onLeave: (() -> Void)?
    var onFocusChanged: (() -> Void)?
    var onJump: ((SurfaceID) -> Void)?
    var onJumpElsewhere: (() -> Void)?
    private let onActivate: (SidebarRowID) -> Void
    private let onNewWorktree: (SidebarRowID) -> Void
    private let onCloseWorkspace: (WorkspaceID) -> Void

    init(
        onActivate: @escaping (SidebarRowID) -> Void, onNewWorktree: @escaping (SidebarRowID) -> Void,
        onCloseWorkspace: @escaping (WorkspaceID) -> Void, onAdd: @escaping () -> Void
    ) {
        self.onActivate = onActivate
        self.onNewWorktree = onNewWorktree
        self.onCloseWorkspace = onCloseWorkspace
        addButton = SidebarFooter.button("plus", "Open workspace", .toggleRepoPicker, onAdd)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        rowStack.orientation = .vertical
        rowStack.alignment = .leading
        rowStack.spacing = 0
        rowStack.translatesAutoresizingMaskIntoConstraints = false
        rowMenu.onOpenChanged = { [weak self] isOpen in
            self?.setHoverCovered(isOpen, exempting: isOpen ? self?.rowMenu.anchor : nil)
        }
        installScroll()
        for view in [caption, addButton, rowStack] { content.addSubview(view) }
        installAgents()

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.width),
            caption.leadingAnchor.constraint(
                equalTo: content.leadingAnchor, constant: Self.padding + Self.captionInset),
            caption.centerYAnchor.constraint(equalTo: content.topAnchor, constant: Self.captionHeight / 2),
            addButton.trailingAnchor.constraint(
                equalTo: content.trailingAnchor, constant: -(Self.padding + Self.addInset)),
            addButton.centerYAnchor.constraint(equalTo: caption.centerYAnchor),
            rowStack.topAnchor.constraint(equalTo: content.topAnchor, constant: Self.captionHeight),
            rowStack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Self.padding),
            rowStack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -Self.padding),
        ])
    }

    private func installScroll() {
        let clip = FlippedClipView()
        clip.drawsBackground = false
        clip.postsBoundsChangedNotifications = true
        scroll.contentView = clip
        scroll.documentView = content
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        clip.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(refreshRowHover), name: NSView.boundsDidChangeNotification, object: clip)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: clip.topAnchor),
            content.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func installAgents() {
        agentStack.orientation = .vertical
        agentStack.alignment = .leading
        agentStack.spacing = 0
        agentStack.translatesAutoresizingMaskIntoConstraints = false
        agentsCaption.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(agentsCaption)
        content.addSubview(agentStack)
        contentEndsAtRows = content.bottomAnchor.constraint(equalTo: rowStack.bottomAnchor)
        contentEndsAtAgents = content.bottomAnchor.constraint(equalTo: agentStack.bottomAnchor)
        NSLayoutConstraint.activate([
            agentsCaption.leadingAnchor.constraint(equalTo: caption.leadingAnchor),
            agentsCaption.centerYAnchor.constraint(
                equalTo: rowStack.bottomAnchor, constant: Self.sectionGap + Self.captionHeight / 2),
            agentStack.topAnchor.constraint(
                equalTo: rowStack.bottomAnchor, constant: Self.sectionGap + Self.captionHeight),
            agentStack.leadingAnchor.constraint(equalTo: rowStack.leadingAnchor),
            agentStack.trailingAnchor.constraint(equalTo: rowStack.trailingAnchor),
        ])
        refreshAgentsSection()
    }

    func limitContent(above anchor: NSLayoutYAxisAnchor) {
        scroll.bottomAnchor.constraint(equalTo: anchor, constant: -Self.contentBottomGap).isActive = true
    }

    // The section outlives this window's own agents: the row alone keeps it up.
    private func refreshAgentsSection() {
        let lostFocusedRow = refreshWaitingRow()
        arrangeAgents()
        let hidden = agentViews.isEmpty && waitingRow == nil
        agentsCaption.isHidden = hidden
        agentStack.isHidden = hidden
        (hidden ? contentEndsAtAgents : contentEndsAtRows)?.isActive = false
        (hidden ? contentEndsAtRows : contentEndsAtAgents)?.isActive = true
        if lostFocusedRow { onLeave?() }
    }

    func renderWaitingElsewhere(agents: Int, windows: Int, index: Int) {
        guard (agents, windows, index) != waitingElsewhere else { return }
        waitingElsewhere = (agents, windows, index)
        refreshAgentsSection()
        refreshRowHover()
    }

    // The row queues with the agents, so its place is theirs to share.
    private func arrangeAgents() {
        var order: [NSView] = agentViews
        if let row = waitingRow { order.insert(row, at: min(waitingElsewhere.index, order.count)) }
        for (index, view) in order.enumerated()
        where agentStack.arrangedSubviews.firstIndex(of: view) != index {
            let isNew = view.superview == nil
            if !isNew { agentStack.removeArrangedSubview(view) }
            agentStack.insertArrangedSubview(view, at: index)
            if isNew { view.widthAnchor.constraint(equalTo: agentStack.widthAnchor).isActive = true }
        }
    }

    // Answers whether the row holding keyboard focus went away, for the caller to act on once the section has settled.
    private func refreshWaitingRow() -> Bool {
        guard waitingElsewhere.agents > 0 else {
            guard let row = waitingRow else { return false }
            let hadFocus = KeyboardFocus.isFocused(row, in: window)
            row.removeFromSuperview()
            waitingRow = nil
            return hadFocus
        }
        let row = waitingRow ?? makeWaitingRow()
        row.render(agents: waitingElsewhere.agents, windows: waitingElsewhere.windows)
        return false
    }

    private func makeWaitingRow() -> SidebarWaitingElsewhereRow {
        let row = SidebarWaitingElsewhereRow { [weak self] in self?.onJumpElsewhere?() }
        row.onArrowUp = { [weak self] in self?.moveFocus(-1) }
        row.onArrowDown = { [weak self] in self?.moveFocus(1) }
        row.onEscape = { [weak self] in self?.onLeave?() }
        row.onFocusChanged = { [weak self] in self?.onFocusChanged?() }
        waitingRow = row
        return row
    }

    func renderAgents(_ items: [SidebarAgentItem]) {
        let ids = Set(items.map(\.id))
        var removedFocusedRow = false
        for (id, row) in agentRows where !ids.contains(id) {
            removedFocusedRow = removedFocusedRow || KeyboardFocus.isFocused(row, in: window)
            row.removeFromSuperview()
            agentRows[id] = nil
        }
        agentViews = items.map { item in
            let row = agentRow(for: item.id)
            row.render(item)
            return row
        }
        refreshAgentsSection()
        refreshRowHover()
        if removedFocusedRow { onLeave?() }
    }

    private func agentRow(for id: SurfaceID) -> SidebarAgentRow {
        if let row = agentRows[id] { return row }
        let row = SidebarAgentRow { [weak self] in self?.onJump?(id) }
        row.onArrowUp = { [weak self] in self?.moveFocus(-1) }
        row.onArrowDown = { [weak self] in self?.moveFocus(1) }
        row.onEscape = { [weak self] in self?.onLeave?() }
        row.onFocusChanged = { [weak self] in self?.onFocusChanged?() }
        agentRows[id] = row
        return row
    }

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
        worktreeParents = Set(items.filter(\.makesWorktrees).map(\.id))
        let previouslyActive = activeRow
        activeRow = items.first(where: \.isActive)?.id
        for (index, item) in items.enumerated() {
            let row = self.row(for: item)
            if rowStack.arrangedSubviews.firstIndex(of: row) != index {
                let isNew = row.superview == nil
                if !isNew { rowStack.removeArrangedSubview(row) }
                rowStack.insertArrangedSubview(row, at: index)
                if isNew { row.widthAnchor.constraint(equalTo: rowStack.widthAnchor).isActive = true }
            }
            row.setTitle(item.name)
            row.setDetail(item.detail)
            row.setSelected(item.isActive)
            setNewWorktreeButton(on: row, for: item)
            row.setShowsAttention(item.isWaiting)
        }
        if activeRow != previouslyActive { revealActiveRow() }
        refreshRowHover()
        if removedFocusedRow { onLeave?() }
    }

    // The keyboard scrolls to the row it focuses, and that wins while the sidebar holds focus.
    private func revealActiveRow() {
        guard !hasFocus, let id = activeRow, let row = rows[id] else { return }
        layoutSubtreeIfNeeded()
        reveal(row)
    }

    // One fade depth of margin, or a row scrolled to an edge lands under the fade.
    private func reveal(_ row: NSView) {
        row.scrollToVisible(row.bounds.insetBy(dx: 0, dy: -FadingScrollView.fadeDepth))
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
        row.onFocusChanged = { [weak self] in self?.onFocusChanged?() }
        row.onReturn = { [weak self] in self?.onActivate(id) }
        row.onEscape = { [weak self] in self?.onLeave?() }
        row.onSecondaryClick = { [weak self, weak row] in
            guard let self, let row else { return }
            self.rowMenu.open(self.menuItems(for: id), from: row)
        }
        rows[item.id] = row
        return row
    }

    // The one place hover is settled, so a row built while a cover is up starts suppressed like the rest.
    @objc private func refreshRowHover() {
        for row in hoverRows {
            row.setHoverSuppressed(hoverCovers > 0 && row !== hoverExempt)
            row.refreshHover()
        }
    }

    func setHoverCovered(_ covered: Bool, exempting exempt: NSView? = nil) {
        let wasCovered = hoverCovers > 0
        hoverCovers = max(0, hoverCovers + (covered ? 1 : -1))
        hoverExempt = covered ? exempt : nil
        refreshRowHover()
        if wasCovered != (hoverCovers > 0) { onHoverCoverChanged?(hoverCovers > 0) }
    }

    var isHoverCovered: Bool { hoverCovers > 0 }

    private var hoverRows: [any HoverSuppressing] {
        Array(rows.values) + Array(agentRows.values) + (waitingRow.map { [$0] } ?? [])
    }

    private func setNewWorktreeButton(on row: SettingsNavRow, for item: SidebarRowItem) {
        guard item.makesWorktrees else { return row.setHoverAccessory(nil) }
        let id = item.id
        guard row.hoverAccessory == nil else { return }
        row.setHoverAccessory(
            IconButton(
                symbol: "plus", size: Self.newWorktreeSize, pointSize: 11, accessibilityLabel: "New worktree",
                shortcut: { CommandCatalog.spec(for: .createWorktree).shortcut }
            ) { [weak self] in self?.onNewWorktree(id) })
    }

    private func menuItems(for row: SidebarRowID) -> [[SidebarRowMenu.Item]] {
        let create = SidebarRowMenu.Item(title: "New Worktree…", action: .createWorktree) { [weak self] in
            self?.onNewWorktree(row)
        }
        let creates = worktreeParents.contains(row) ? [create] : []
        guard case .workspace(let id) = row else { return [creates] }
        let close = SidebarRowMenu.Item(
            title: "Close Workspace", action: row == activeRow ? .closeWorkspace : nil
        ) { [weak self] in
            self?.onCloseWorkspace(id)
        }
        return [creates + [close]]
    }

    override func viewDidHide() {
        super.viewDidHide()
        rowMenu.close()
    }

    var hasFocus: Bool { focusStops.contains { KeyboardFocus.isFocused($0, in: window) } }

    var agentsSectionHasFocus: Bool {
        agentStack.arrangedSubviews.contains { KeyboardFocus.isFocused($0, in: window) }
    }

    var focusedRow: SidebarRowID? { rows.first { KeyboardFocus.isFocused($0.value, in: window) }?.key }

    var focusedStop: SidebarFocusStop? {
        if let id = focusedRow { return .row(id) }
        if let row = waitingRow, KeyboardFocus.isFocused(row, in: window) { return .waitingElsewhere }
        return agentRows.first { KeyboardFocus.isFocused($0.value, in: window) }.map { .agent($0.key) }
    }

    @discardableResult
    func focusStop(_ stop: SidebarFocusStop) -> Bool {
        switch stop {
        case .row(let id): return focusRow(id)
        case .agent(let id):
            guard let row = agentRows[id] else { return false }
            row.takeKeyboardFocus()
            reveal(row)
            return true
        case .waitingElsewhere:
            guard let row = waitingRow else { return false }
            row.takeKeyboardFocus()
            reveal(row)
            return true
        }
    }

    @discardableResult
    func focusRow(_ id: SidebarRowID) -> Bool {
        guard let row = rows[id] else { return false }
        row.takeKeyboardFocus()
        reveal(row)
        return true
    }

    private func moveFocus(_ delta: Int) {
        let stops = focusStops
        let current = stops.firstIndex { KeyboardFocus.isFocused($0, in: window) }
        guard let next = KeyboardFocus.step(from: current, delta: delta, count: stops.count) else { return }
        switch stops[next] {
        case let row as SettingsNavRow: row.takeKeyboardFocus()
        case let row as SidebarAgentRow: row.takeKeyboardFocus()
        case let row as SidebarWaitingElsewhereRow: row.takeKeyboardFocus()
        default: return
        }
        reveal(stops[next])
    }

    private var focusStops: [NSView] { orderedRows + agentStack.arrangedSubviews }

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
        rowMenu.close()
        caption.reapplyTheme()
        addButton.reapplyTheme()
        agentsCaption.reapplyTheme()
        for row in rows.values {
            row.reapplyTheme()
            (row.hoverAccessory as? IconButton)?.reapplyTheme()
        }
        for row in agentRows.values { row.reapplyTheme() }
        waitingRow?.reapplyTheme()
    }

    var addButtonForTesting: IconButton { addButton }

    var rowsForTesting: [SettingsNavRow] { orderedRows }

    var agentRowsForTesting: [SidebarAgentRow] { orderedAgentRows }

    var agentsAreHiddenForTesting: Bool { agentStack.isHidden && agentsCaption.isHidden }

    var waitingElsewhereRowForTesting: SidebarWaitingElsewhereRow? { waitingRow }

    var agentSectionForTesting: [NSView] { agentStack.arrangedSubviews }

    var scrollForTesting: FadingScrollView { scroll }
}
