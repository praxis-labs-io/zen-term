import AppKit

enum SidebarRowID: Hashable {
    case workspace(WorkspaceID)
    case ghost(String)
}

enum SidebarFocusStop: Equatable {
    case row(SidebarRowID)
    case host(String)
    case agent(SurfaceID)
}

struct SidebarHostItem: Equatable {
    let id: SSHHostID
    let name: String
    let status: SSHHostStatus
    let number: Int?
    let isActive: Bool
}

struct SidebarRowItem: Equatable {
    let id: SidebarRowID
    let variant: NavRow.Variant
    let name: String
    let detail: String?
    let number: Int?
    let isActive: Bool
    let makesWorktrees: Bool
}

final class SidebarView: NSView, ThemeReapplying {
    static let width: CGFloat = 240
    static let padding: CGFloat = ChromeMetrics.Spacing.s8
    private static let captionHeight: CGFloat = ChromeMetrics.Height.control
    private static let captionInset: CGFloat = ChromeMetrics.Spacing.controlInset
    static let captionLeading = padding + captionInset
    static let windowButtonStripHeight: CGFloat = ChromeMetrics.Height.control
    private static let addInset: CGFloat = ChromeMetrics.Spacing.s4
    private static let newWorktreeSize = NSSize(width: ChromeMetrics.Height.xs, height: ChromeMetrics.Height.xs)
    private static let sectionGap: CGFloat = ChromeMetrics.Spacing.s12
    private static let contentBottomGap: CGFloat = ChromeMetrics.Spacing.s8

    private var scrollTop: NSLayoutConstraint?
    private let caption = SectionCaption("Workspaces")
    private let addButton: IconButton
    private let rowStack = NSStackView()
    private var rows: [SidebarRowID: NavRow] = [:]
    private var numbers: [SidebarRowID: Int] = [:]
    private var worktreeParents: Set<SidebarRowID> = []
    private var activeRow: SidebarRowID?
    private var hoverCovers = 0
    private weak var hoverExempt: NSView?
    let rowMenu = SidebarRowMenu()
    private let hostsCaption = SectionCaption("Remote hosts")
    private let hostStack = NSStackView()
    private var hostRows: [String: NavRow] = [:]
    private var hostNumbers: [String: Int] = [:]
    private var hostsBelowRows: [NSLayoutConstraint] = []
    private var agentsBelowRows: [NSLayoutConstraint] = []
    private var agentsBelowHosts: [NSLayoutConstraint] = []
    private var contentEndsAtHosts: NSLayoutConstraint?
    private let agentsCaption = SectionCaption("Agents")
    private let agentStack = NSStackView()
    private let scroll = FadingScrollView()
    private let content = FlippedView()
    private lazy var fillSlide = RowFillSlide(host: content)
    private var contentEndsAtRows: NSLayoutConstraint?
    private var contentEndsAtAgents: NSLayoutConstraint?
    private var agentRows: [SurfaceID: SidebarAgentRow] = [:]
    private var agentViews: [SidebarAgentRow] = []
    var onHoverCoverChanged: ((Bool) -> Void)?
    var onLeave: (() -> Void)?
    var onFocusChanged: (() -> Void)?
    var onJump: ((SurfaceID) -> Void)?
    var onCloseAgent: ((SurfaceID) -> Void)?
    var onActivateHost: ((SSHHostID) -> Void)?
    private let onActivate: (SidebarRowID) -> Void
    private let onNewWorktree: (SidebarRowID) -> Void
    private let onRenameWorkspace: (WorkspaceID) -> Void
    private let onCloseWorkspace: (WorkspaceID) -> Void

    init(
        onActivate: @escaping (SidebarRowID) -> Void, onNewWorktree: @escaping (SidebarRowID) -> Void,
        onRenameWorkspace: @escaping (WorkspaceID) -> Void, onCloseWorkspace: @escaping (WorkspaceID) -> Void,
        onAdd: @escaping () -> Void
    ) {
        self.onActivate = onActivate
        self.onNewWorktree = onNewWorktree
        self.onRenameWorkspace = onRenameWorkspace
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
        reapplyWindowButtonStrip()
        for view in [caption, addButton, rowStack] { content.addSubview(view) }
        installHosts()
        installAgents()

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.width),
            caption.leadingAnchor.constraint(
                equalTo: content.leadingAnchor, constant: Self.captionLeading),
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
        let scrollTop = scroll.topAnchor.constraint(equalTo: topAnchor)
        self.scrollTop = scrollTop
        NSLayoutConstraint.activate([
            scrollTop,
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: clip.topAnchor),
            content.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func installHosts() {
        hostStack.orientation = .vertical
        hostStack.alignment = .leading
        hostStack.spacing = 0
        hostStack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(hostsCaption)
        content.addSubview(hostStack)
        contentEndsAtHosts = content.bottomAnchor.constraint(equalTo: hostStack.bottomAnchor)
        hostsBelowRows = section(hostsCaption, hostStack, below: rowStack.bottomAnchor)
        NSLayoutConstraint.activate(
            hostsBelowRows + [
                hostsCaption.leadingAnchor.constraint(equalTo: caption.leadingAnchor),
                hostStack.leadingAnchor.constraint(equalTo: rowStack.leadingAnchor),
                hostStack.trailingAnchor.constraint(equalTo: rowStack.trailingAnchor),
            ])
    }

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
        agentsBelowRows = section(agentsCaption, agentStack, below: rowStack.bottomAnchor)
        agentsBelowHosts = section(agentsCaption, agentStack, below: hostStack.bottomAnchor)
        NSLayoutConstraint.activate([
            agentsCaption.leadingAnchor.constraint(equalTo: caption.leadingAnchor),
            agentStack.leadingAnchor.constraint(equalTo: rowStack.leadingAnchor),
            agentStack.trailingAnchor.constraint(equalTo: rowStack.trailingAnchor),
        ])
        refreshSections()
    }

    private func section(
        _ caption: NSView, _ stack: NSView, below anchor: NSLayoutYAxisAnchor
    ) -> [NSLayoutConstraint] {
        [
            caption.centerYAnchor.constraint(equalTo: anchor, constant: Self.sectionGap + Self.captionHeight / 2),
            stack.topAnchor.constraint(equalTo: anchor, constant: Self.sectionGap + Self.captionHeight),
        ]
    }

    func limitContent(above anchor: NSLayoutYAxisAnchor) {
        scroll.bottomAnchor.constraint(equalTo: anchor, constant: -Self.contentBottomGap).isActive = true
    }

    private func refreshAgentsSection() {
        arrangeAgents()
        refreshSections()
    }

    // A hidden section takes its gap with it, so each visible one hangs off the last visible one above it.
    private func refreshSections() {
        let showsHosts = !hostRows.isEmpty
        let showsAgents = !agentViews.isEmpty
        hostsCaption.isHidden = !showsHosts
        hostStack.isHidden = !showsHosts
        agentsCaption.isHidden = !showsAgents
        agentStack.isHidden = !showsAgents
        NSLayoutConstraint.deactivate(
            (showsHosts ? agentsBelowRows : agentsBelowHosts)
                + [contentEndsAtRows, contentEndsAtHosts, contentEndsAtAgents].compactMap { $0 })
        NSLayoutConstraint.activate(showsHosts ? agentsBelowHosts : agentsBelowRows)
        let end = showsAgents ? contentEndsAtAgents : showsHosts ? contentEndsAtHosts : contentEndsAtRows
        end?.isActive = true
    }

    func renderHosts(_ items: [SidebarHostItem]) {
        let byName = Dictionary(uniqueKeysWithValues: items.map { ($0.id.alias, $0) })
        var removedFocusedRow = false
        for (host, row) in hostRows where byName[host] == nil {
            removedFocusedRow = removedFocusedRow || KeyboardFocus.isFocused(row, in: window)
            row.removeFromSuperview()
            hostRows[host] = nil
        }
        hostNumbers = byName.compactMapValues(\.number)
        for (index, item) in items.enumerated() {
            let row = hostRow(for: item)
            row.setTitle(item.name)
            row.isCurrent = item.isActive
            row.setDetail(item.status.word)
            row.setTitleInk(item.status == .connected ? nil : .subtle)
            guard hostStack.arrangedSubviews.firstIndex(of: row) != index else { continue }
            let isNew = row.superview == nil
            if !isNew { hostStack.removeArrangedSubview(row) }
            hostStack.insertArrangedSubview(row, at: index)
            if isNew { row.widthAnchor.constraint(equalTo: hostStack.widthAnchor).isActive = true }
        }
        refreshSections()
        refreshRowHover()
        if removedFocusedRow { onLeave?() }
    }

    // Only ⌘⌃1…9 exist, so a row numbered past nine has no shortcut to show.
    private static func selectShortcut(_ number: Int?) -> String? {
        guard let number, number <= 9 else { return nil }
        return CommandCatalog.spec(for: .selectWorkspace(number)).shortcut
    }

    private func hostRow(for item: SidebarHostItem) -> NavRow {
        let host = item.id.alias
        if let row = hostRows[host] { return row }
        let id = item.id
        let row = NavRow(title: item.name, focusesOnClick: false) {
            [weak self] in self?.onActivateHost?(id)
        }
        row.tooltip = TooltipHost(label: "Open host") { [weak self] in
            Self.selectShortcut(self?.hostNumbers[host])
        }
        row.onArrowUp = { [weak self] in self?.moveFocus(-1) }
        row.onArrowDown = { [weak self] in self?.moveFocus(1) }
        row.onFocusChanged = { [weak self] in self?.onFocusChanged?() }
        row.onReturn = { [weak self] in self?.onActivateHost?(id) }
        row.onEscape = { [weak self] in self?.onLeave?() }
        fillSlide.adopt(row)
        hostRows[host] = row
        return row
    }

    private func arrangeAgents() {
        for (index, view) in agentViews.enumerated()
        where agentStack.arrangedSubviews.firstIndex(of: view) != index {
            let isNew = view.superview == nil
            if !isNew { agentStack.removeArrangedSubview(view) }
            agentStack.insertArrangedSubview(view, at: index)
            if isNew { view.widthAnchor.constraint(equalTo: agentStack.widthAnchor).isActive = true }
        }
    }

    func renderAgents(_ items: [SidebarAgentItem]) {
        let ids = Set(items.map(\.id))
        var removedFocusedRow = false
        for (id, row) in agentRows where !ids.contains(id) {
            removedFocusedRow = removedFocusedRow || KeyboardFocus.isFocused(row, in: window)
            if rowMenu.anchor === row { rowMenu.close() }
            row.removeFromSuperview()
            agentRows[id] = nil
        }
        agentViews = items.map { item in
            let row = agentRow(for: item.id)
            row.render(item)
            wireMenu(of: row, for: item.id)
            return row
        }
        refreshAgentsSection()
        refreshRowHover()
        if removedFocusedRow { onLeave?() }
    }

    private func agentRow(for id: SurfaceID) -> SidebarAgentRow {
        if let row = agentRows[id] { return row }
        let row = SidebarAgentRow { [weak self] in self?.onJump?(id) }
        wire(row)
        row.onArrowUp = { [weak self, weak row] in self?.arrow(-1, on: row) }
        row.onArrowDown = { [weak self, weak row] in self?.arrow(1, on: row) }
        row.onReturn = { [weak self, weak row] in
            guard let self else { return }
            if self.isMenuOpen(on: row), self.rowMenu.chooseHighlighted() { return }
            self.rowMenu.close()
            self.onJump?(id)
        }
        fillSlide.adopt(row)
        agentRows[id] = row
        return row
    }

    // A row with no menu keeps no handlers, so ⌃-click stays a plain click that jumps.
    private func wireMenu(of row: SidebarAgentRow, for id: SurfaceID) {
        guard row.canClose else {
            if isMenuOpen(on: row) { rowMenu.close() }
            row.onSpace = nil
            row.onSecondaryClick = nil
            return
        }
        row.onSpace = { [weak self, weak row] in
            guard let self, let row, !self.isMenuOpen(on: row) else { return }
            self.rowMenu.open(self.agentMenuItems(for: id), from: row, highlightingFirst: true)
        }
        row.onSecondaryClick = { [weak self, weak row] in
            guard let self, let row else { return }
            self.rowMenu.open(self.agentMenuItems(for: id), from: row)
        }
    }

    private func agentMenuItems(for id: SurfaceID) -> [[SidebarRowMenu.Item]] {
        [[SidebarRowMenu.Item(title: "Close", action: nil) { [weak self] in self?.onCloseAgent?(id) }]]
    }

    private func wire(_ row: SidebarJumpRow) {
        row.onArrowUp = { [weak self] in self?.moveFocus(-1) }
        row.onArrowDown = { [weak self] in self?.moveFocus(1) }
        row.onEscape = { [weak self] in self?.onLeave?() }
        row.onFocusChanged = { [weak self] in self?.onFocusChanged?() }
    }

    func render(_ items: [SidebarRowItem]) {
        rendersForTesting += 1
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
            row.isCurrent = item.isActive
            setNewWorktreeButton(on: row, for: item)
        }
        if activeRow != previouslyActive { revealActiveRow() }
        refreshRowHover()
        if removedFocusedRow { onLeave?() }
    }

    // The keyboard scrolls to the row it focuses, and that wins while the sidebar holds focus.
    private func revealActiveRow() {
        guard !hasFocus, let id = activeRow, let row = rows[id] else { return }
        layoutSubtreeIfNeeded()
        scroll.reveal(row)
    }

    private func row(for item: SidebarRowItem) -> NavRow {
        if let row = rows[item.id] { return row }
        let id = item.id
        let row = NavRow(title: item.name, variant: item.variant, focusesOnClick: false) {
            [weak self] in self?.onActivate(id)
        }
        if case .workspace = id {
            row.tooltip = TooltipHost(label: "Switch workspace") { [weak self] in
                Self.selectShortcut(self?.numbers[id])
            }
        }
        row.onArrowUp = { [weak self, weak row] in self?.arrow(-1, on: row) }
        row.onArrowDown = { [weak self, weak row] in self?.arrow(1, on: row) }
        row.onFocusChanged = { [weak self] in self?.onFocusChanged?() }
        row.onReturn = { [weak self, weak row] in
            guard let self else { return }
            if self.isMenuOpen(on: row), self.rowMenu.chooseHighlighted() { return }
            self.rowMenu.close()
            self.onActivate(id)
        }
        row.onSpace = { [weak self, weak row] in
            guard let self, let row, !self.isMenuOpen(on: row) else { return }
            self.rowMenu.open(self.menuItems(for: id), from: row, highlightingFirst: true)
        }
        row.onEscape = { [weak self] in self?.onLeave?() }
        row.onSecondaryClick = { [weak self, weak row] in
            guard let self, let row else { return }
            self.rowMenu.open(self.menuItems(for: id), from: row)
        }
        fillSlide.adopt(row)
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
        Array(rows.values) + Array(hostRows.values) + Array(agentRows.values)
    }

    private func setNewWorktreeButton(on row: NavRow, for item: SidebarRowItem) {
        guard item.makesWorktrees else { return row.setHoverAccessory(nil) }
        let id = item.id
        guard row.hoverAccessory == nil else { return }
        row.setHoverAccessory(
            IconButton(
                symbol: "plus", size: Self.newWorktreeSize, pointSize: ChromeMetrics.Icon.sm,
                accessibilityLabel: "New worktree",
                shortcut: { CommandCatalog.spec(for: .createWorktree).shortcut }
            ) { [weak self] in self?.onNewWorktree(id) })
    }

    private func menuItems(for row: SidebarRowID) -> [[SidebarRowMenu.Item]] {
        let create = SidebarRowMenu.Item(title: "New Worktree…", action: .createWorktree) { [weak self] in
            self?.onNewWorktree(row)
        }
        let creates = worktreeParents.contains(row) ? [create] : []
        guard case .workspace(let id) = row else { return [creates] }
        let rename = SidebarRowMenu.Item(
            title: "Rename Workspace…", action: row == activeRow ? .renameWorkspace : nil
        ) { [weak self] in
            self?.onRenameWorkspace(id)
        }
        let close = SidebarRowMenu.Item(
            title: "Close Workspace", action: row == activeRow ? .closeWorkspace : nil
        ) { [weak self] in
            self?.onCloseWorkspace(id)
        }
        return [creates + [rename, close]]
    }

    override func viewDidHide() {
        super.viewDidHide()
        rowMenu.close()
    }

    private func isMenuOpen(on row: ListRow?) -> Bool { rowMenu.isOpen && row != nil && rowMenu.anchor === row }

    private func arrow(_ delta: Int, on row: ListRow?) {
        if isMenuOpen(on: row) { rowMenu.moveHighlight(delta) } else { moveFocus(delta) }
    }

    var hasFocus: Bool { focusStops.contains { KeyboardFocus.isFocused($0, in: window) } }

    var agentsSectionHasFocus: Bool {
        agentStack.arrangedSubviews.contains { KeyboardFocus.isFocused($0, in: window) }
    }

    var hostsSectionHasFocus: Bool {
        hostStack.arrangedSubviews.contains { KeyboardFocus.isFocused($0, in: window) }
    }

    var focusedRow: SidebarRowID? { rows.first { KeyboardFocus.isFocused($0.value, in: window) }?.key }

    var focusedStop: SidebarFocusStop? {
        if let id = focusedRow { return .row(id) }
        if let host = hostRows.first(where: { KeyboardFocus.isFocused($0.value, in: window) })?.key {
            return .host(host)
        }
        return agentRows.first { KeyboardFocus.isFocused($0.value, in: window) }.map { .agent($0.key) }
    }

    @discardableResult
    func focusStop(_ stop: SidebarFocusStop) -> Bool {
        switch stop {
        case .row(let id): return focusRow(id)
        case .host(let host):
            guard let row = hostRows[host] else { return false }
            row.takeKeyboardFocus()
            scroll.reveal(row)
            return true
        case .agent(let id):
            guard let row = agentRows[id] else { return false }
            row.takeKeyboardFocus()
            scroll.reveal(row)
            return true
        }
    }

    @discardableResult
    func focusRow(_ id: SidebarRowID) -> Bool {
        guard let row = rows[id] else { return false }
        row.takeKeyboardFocus()
        scroll.reveal(row)
        return true
    }

    private func moveFocus(_ delta: Int) {
        let stops = focusStops
        let current = stops.firstIndex { KeyboardFocus.isFocused($0, in: window) }
        guard let next = KeyboardFocus.step(from: current, delta: delta, count: stops.count) else { return }
        guard let row = stops[next] as? ListRow else { return }
        row.takeKeyboardFocus()
        scroll.reveal(stops[next])
    }

    private var focusStops: [NSView] { orderedRows + hostStack.arrangedSubviews + agentStack.arrangedSubviews }

    private var orderedAgentRows: [SidebarAgentRow] {
        agentStack.arrangedSubviews.compactMap { $0 as? SidebarAgentRow }
    }

    override func keyDown(with event: NSEvent) {
        switch KeyboardFocus.key(for: event) {
        case .left, .right, .tab: return
        default: super.keyDown(with: event)
        }
    }

    private var orderedRows: [NavRow] {
        rowStack.arrangedSubviews.compactMap { $0 as? NavRow }
    }

    func reapplyTheme() {
        rowMenu.close()
    }

    // The window's buttons sit over this strip, above the scroll area, so the rows scroll beneath them.
    func reapplyWindowButtonStrip() {
        scrollTop?.constant = GeneralConfig.current.windowChrome ? Self.windowButtonStripHeight : 0
    }

    var addButtonForTesting: IconButton { addButton }

    var rowsForTesting: [NavRow] { orderedRows }

    private(set) var rendersForTesting = 0

    var agentRowsForTesting: [SidebarAgentRow] { orderedAgentRows }

    var hostRowsForTesting: [NavRow] { hostStack.arrangedSubviews.compactMap { $0 as? NavRow } }

    var hostsAreHiddenForTesting: Bool { hostStack.isHidden && hostsCaption.isHidden }

    var agentsAreHiddenForTesting: Bool { agentStack.isHidden && agentsCaption.isHidden }

    var agentSectionForTesting: [NSView] { agentStack.arrangedSubviews }

    var scrollForTesting: FadingScrollView { scroll }

    var fillSlideForTesting: RowFillSlide { fillSlide }
}
