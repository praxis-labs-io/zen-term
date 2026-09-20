import AppKit
import TerminalKit

// Docks and collapses one window's sidebar, and owns the edges the canvas, tool floats and tab bar start from.
@MainActor
final class SidebarController {
    private static var lastChoiceIsDocked = true

    private struct Entry {
        enum Kind { case workspace, worktree(WorktreeOrigin), ghost }

        let row: SidebarRowID
        let kind: Kind
        let name: String
        let folder: URL?
        let number: Int?
        let isActive: Bool
        let isConfigured: Bool
        let isWaiting: Bool
    }

    // 8 of sidebar padding plus the footer's 6 inset, so palette and Settings follow at the footer's rhythm.
    private static let toggleInset: CGFloat = 14
    private static let toggleCardInset = SidebarView.padding + SidebarFooter.buttonSize.height / 2
    // The toggle keeps its own place in the window, so the rest of the footer starts where its slot ends.
    private static let footerInset = toggleInset + SidebarFooter.buttonSize.width + SidebarFooter.spacing
    private static var toggleCardLeading: CGFloat { ChromeMetrics.windowGutter + toggleInset }
    private static let leadNameGap: CGFloat = 6
    // Docking below this would leave the panes less than the window's own minimum, so the sidebar floats instead.
    static let minimumDockableWidth = HostWindow.minimumContentSize.width + SidebarView.width

    let column: SidebarColumn
    let lead: CollapsedSidebarLead
    let edgeReveal = SidebarEdgeReveal()
    private let toggleButton: IconButton
    private let edge = NSLayoutGuide()
    private let canvasEdge = NSLayoutGuide()
    private(set) var isDocked = SidebarController.lastChoiceIsDocked
    private(set) var isRevealed = false
    private var revealHoldsFocus = false
    private var edgeLeading: NSLayoutConstraint?
    private var canvasOffset: NSLayoutConstraint?
    private var leadWidth: NSLayoutConstraint?
    private var tabBarLeading: NSLayoutConstraint?
    private var sidebarTop: NSLayoutConstraint?
    private var columnLeading: NSLayoutConstraint?
    private var columnBottom: NSLayoutConstraint?
    private var toggleLeading: NSLayoutConstraint?
    private var toggleAtChipBand: NSLayoutConstraint?
    private var toggleAboveCard: NSLayoutConstraint?
    private var slideID = 0
    private var revealID = 0
    private var isSliding = false
    private var entries: [Entry] = []
    var onLeave: () -> Void = {}
    var onFocusChanged: () -> Void = {}
    var onJump: (SurfaceID) -> Void = { _ in }
    var onRevealChanged: () -> Void = {}
    var onFocusYield: () -> Void = {}
    var onFocusRestore: () -> Void = {}

    init(
        onPalette: @escaping () -> Void, onSettings: @escaping () -> Void, onToggle: @escaping () -> Void,
        onActivate: @escaping (SidebarRowID) -> Void, onNewWorktree: @escaping (SidebarRowID) -> Void,
        onCloseWorkspace: @escaping (WorkspaceID) -> Void, onAdd: @escaping () -> Void
    ) {
        column = SidebarColumn(
            onPalette: onPalette, onSettings: onSettings, onActivate: onActivate,
            onNewWorktree: onNewWorktree, onCloseWorkspace: onCloseWorkspace, onAdd: onAdd)
        toggleButton = SidebarFooter.button("sidebar.left", "Toggle sidebar", .toggleSidebar, onToggle)
        lead = CollapsedSidebarLead(
            leadingInset: Self.toggleInset + SidebarFooter.buttonSize.width + Self.leadNameGap)
        edgeReveal.onReveal = { [weak self] in self?.reveal() }
        edgeReveal.onHide = { [weak self] in self?.hideReveal() }
        edgeReveal.isPinned = { [weak self] in self?.isRevealPinned() ?? false }
        view.onHoverCoverChanged = { [weak self] _ in self?.edgeReveal.recheck() }
        view.onLeave = { [weak self] in
            self?.hideReveal(restoringFocus: false)
            self?.onLeave()
        }
        view.onFocusChanged = { [weak self] in self?.onFocusChanged() }
        view.onJump = { [weak self] in self?.onJump($0) }
    }

    var view: SidebarView { column.rows }

    var footer: SidebarFooter { column.footer }

    var edgeAnchor: NSLayoutXAxisAnchor { edge.leadingAnchor }
    var canvasLeadingAnchor: NSLayoutXAxisAnchor { canvasEdge.leadingAnchor }

    func install(in container: NSView, besideTabBar tabBar: TabBarView) {
        container.addSubview(lead)
        container.addSubview(column)
        container.addSubview(toggleButton)
        container.addLayoutGuide(edge)
        container.addLayoutGuide(canvasEdge)
        let edgeLeading = edge.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: edgeOffset)
        let canvasOffset = canvasEdge.leadingAnchor.constraint(equalTo: edge.leadingAnchor, constant: canvasGap)
        let leadWidth = lead.widthAnchor.constraint(equalToConstant: leadOffset)
        let tabBarLeading = tabBar.leadingAnchor.constraint(equalTo: lead.trailingAnchor, constant: tabBarPull)
        let sidebarTop = column.topAnchor.constraint(equalTo: container.topAnchor, constant: ChromeMetrics.topInset)
        let columnLeading = column.leadingAnchor.constraint(equalTo: container.leadingAnchor)
        let columnBottom = column.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        let toggleAtChipBand = toggleButton.centerYAnchor.constraint(equalTo: tabBar.chipBandCenterYAnchor)
        let toggleLeading = toggleButton.leadingAnchor.constraint(
            equalTo: container.leadingAnchor, constant: Self.toggleInset)
        self.toggleLeading = toggleLeading
        self.columnLeading = columnLeading
        self.columnBottom = columnBottom
        self.toggleAtChipBand = toggleAtChipBand
        self.toggleAboveCard = toggleButton.centerYAnchor.constraint(
            equalTo: column.bottomAnchor, constant: -Self.toggleCardInset)
        self.edgeLeading = edgeLeading
        self.canvasOffset = canvasOffset
        self.leadWidth = leadWidth
        self.tabBarLeading = tabBarLeading
        self.sidebarTop = sidebarTop
        NSLayoutConstraint.activate([
            edgeLeading,
            edge.widthAnchor.constraint(equalToConstant: 0),
            edge.topAnchor.constraint(equalTo: container.topAnchor),
            edge.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            canvasOffset,
            canvasEdge.widthAnchor.constraint(equalToConstant: 0),
            canvasEdge.topAnchor.constraint(equalTo: container.topAnchor),
            canvasEdge.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            columnLeading,
            sidebarTop,
            columnBottom,
            toggleLeading,
            toggleAtChipBand,
            footer.leadingAnchor.constraint(equalTo: column.leadingAnchor, constant: Self.footerInset),
            footer.centerYAnchor.constraint(equalTo: toggleButton.centerYAnchor),
            lead.leadingAnchor.constraint(equalTo: edge.leadingAnchor),
            lead.centerYAnchor.constraint(equalTo: tabBar.chipBandCenterYAnchor),
            leadWidth,
            tabBarLeading,
        ])
        view.limitContent(above: toggleButton.topAnchor)
        edgeReveal.install(in: container)
        settle()
    }

    private var edgeOffset: CGFloat { isDocked ? SidebarView.width : 0 }
    private var leadOffset: CGFloat { isDocked ? 0 : lead.contentWidth }
    // Docked, it moves in with the canvas; collapsed, the divider sits as far from the first title as from the name.
    private var tabBarPull: CGFloat {
        isDocked ? -SidebarView.padding : CollapsedSidebarLead.dividerGap - TabBarView.titleInset
    }
    // The canvas insets itself by window-gutter; docked, it sits one pane-gap from the rows' fill, as from a drawer.
    private var canvasGap: CGFloat {
        isDocked ? ChromeMetrics.panelGap - ChromeMetrics.windowGutter - SidebarView.padding : 0
    }

    func toggle(holding surfaces: [TerminalSurface], in root: NSView) {
        guard let edgeLeading, let canvasOffset, let leadWidth, let tabBarLeading, let columnLeading,
            let columnBottom
        else { return }
        let wasRevealed = isRevealed
        isRevealed = false
        revealID &+= 1
        edgeReveal.setRevealed(false)
        setToggleOnCard(false)
        isDocked.toggle()
        Self.lastChoiceIsDocked = isDocked
        column.setContentHidden(false)
        lead.isHidden = false
        Motion.fade(footer, to: isDocked ? 1 : 0, duration: Motion.pageSlideDuration)
        slideID &+= 1
        let animate = [
            (edgeLeading, edgeOffset), (canvasOffset, canvasGap), (leadWidth, leadOffset),
            (tabBarLeading, tabBarPull), (columnLeading, 0), (columnBottom, 0),
        ]
        guard !Motion.isReduceMotionEnabled() else {
            for (constraint, target) in animate { constraint.constant = target }
            dockCard()
            settle()
            root.layoutSubtreeIfNeeded()
            return
        }
        let id = slideID
        isSliding = true
        if wasRevealed { fadeCardChrome() }
        Motion.drawerSlide(
            panel: view, opening: isDocked,
            parkOffset: wasRevealed ? .zero : CGVector(dx: -SidebarView.width, dy: 0),
            animate: animate, in: root,
            beforeSlide: { surfaces.forEach { $0.setSizeSyncSuspended(true) } }
        ) { [weak self] in
            surfaces.forEach { $0.setSizeSyncSuspended(false) }
            guard let self, self.slideID == id else { return }
            self.isSliding = false
            self.view.layer?.transform = CATransform3DIdentity
            self.dockCard()
            self.applyLeadWidth()
            self.settle()
        }
    }

    // The radius, edge and shadow would otherwise pop flat in one frame as the card lands against the window.
    private func fadeCardChrome() {
        guard let layer = column.layer else { return }
        for (keyPath, value) in [("cornerRadius", CGFloat(0)), ("borderWidth", 0)] {
            Motion.ease(layer, keyPath: keyPath, to: value, duration: Motion.pageSlideDuration)
        }
        Motion.ease(layer, keyPath: "shadowOpacity", to: Float(0), duration: Motion.pageSlideDuration)
    }

    private func dockCard() {
        column.setFloating(false)
        column.layer?.opacity = 1
        column.layer?.transform = CATransform3DIdentity
    }

    // Not the user's choice to collapse, so the remembered one is left alone for the next window.
    func yieldToNarrowWindow(in root: NSView) {
        guard isDocked, let edgeLeading, let canvasOffset, let leadWidth, let tabBarLeading else { return }
        isDocked = false
        slideID &+= 1
        isSliding = false
        edgeLeading.constant = edgeOffset
        canvasOffset.constant = canvasGap
        leadWidth.constant = leadOffset
        tabBarLeading.constant = tabBarPull
        view.layer?.transform = CATransform3DIdentity
        settle()
        applyLeadWidth()
        root.layoutSubtreeIfNeeded()
    }

    private func settle() {
        column.setContentHidden(!isShown)
        footer.layer?.opacity = isShown ? 1 : 0
        lead.isHidden = isDocked
    }

    var isShown: Bool { isDocked || isRevealed }

    private var revealPark: CGVector {
        CGVector(dx: -(SidebarView.width + ChromeMetrics.windowGutter), dy: 0)
    }

    func reveal(takingFocus: Bool = false) {
        guard !isDocked, !isRevealed, let columnLeading, let columnBottom else { return }
        isRevealed = true
        revealHoldsFocus = takingFocus
        revealID &+= 1
        setToggleOnCard(true)
        columnLeading.constant = ChromeMetrics.windowGutter
        columnBottom.constant = -ChromeMetrics.windowGutter
        column.setFloating(true)
        edgeReveal.setRevealed(true)
        settle()
        column.superview?.layoutSubtreeIfNeeded()
        Motion.slideFade(column, appearing: true, from: revealPark)
        onRevealChanged()
        guard takingFocus else { return }
        onFocusYield()
        focusActiveRow()
    }

    // Taking the keyboard also takes the card off the pointer, which no longer dismisses it.
    func focusRevealedCard() {
        guard isRevealed, !revealHoldsFocus else { return }
        revealHoldsFocus = true
        onFocusYield()
        focusActiveRow()
    }

    func toggleFloat() {
        if isRevealed { hideReveal() } else { reveal(takingFocus: true) }
    }

    func hideReveal(restoringFocus: Bool = true) {
        guard isRevealed, let columnLeading, let columnBottom else { return }
        let handBackFocus = restoringFocus && view.hasFocus
        isRevealed = false
        revealHoldsFocus = false
        revealID &+= 1
        let id = revealID
        edgeReveal.setRevealed(false)
        setToggleOnCard(false)
        onRevealChanged()
        if handBackFocus { onFocusRestore() }
        Motion.slideFade(column, appearing: false, from: revealPark) { [weak self] in
            guard let self, self.revealID == id else { return }
            columnLeading.constant = 0
            columnBottom.constant = 0
            self.column.setFloating(false)
            self.column.layer?.opacity = 1
            self.column.layer?.transform = CATransform3DIdentity
            self.settle()
        }
    }

    var isHoverCovered: Bool { view.isHoverCovered }

    private func isRevealPinned() -> Bool {
        view.hasFocus || view.isHoverCovered || isPinnedExternally()
    }

    var isPinnedExternally: () -> Bool = { false }

    private func setToggleOnCard(_ onCard: Bool) {
        toggleAtChipBand?.isActive = !onCard
        toggleAboveCard?.isActive = onCard
        applyToggleLeading()
    }

    private func applyToggleLeading() {
        toggleLeading?.constant = toggleAboveCard?.isActive == true ? Self.toggleCardLeading : Self.toggleInset
    }

    func render(
        order: WorkspaceOrder, workspaces: [WorkspaceController], active: WorkspaceController,
        waiting: Set<WorkspaceID>
    ) {
        let byID = Dictionary(uniqueKeysWithValues: workspaces.map { ($0.id, $0) })
        let numbers = Dictionary(uniqueKeysWithValues: order.navigable.enumerated().map { ($1, $0 + 1) })
        let next = order.entries.compactMap { entry -> Entry? in
            switch entry {
            case .workspace(let id), .worktree(let id):
                guard let workspace = byID[id] else { return nil }
                let kind = workspace.origin.map(Entry.Kind.worktree) ?? .workspace
                return Entry(
                    row: .workspace(id), kind: kind, name: workspace.name, folder: workspace.folder,
                    number: numbers[id], isActive: workspace === active, isConfigured: workspace.isConfigured,
                    isWaiting: waiting.contains(id))
            case .ghost(let parent):
                return Entry(
                    row: .ghost(parent.path.standardizedFileURL.path), kind: .ghost, name: parent.title,
                    folder: nil, number: nil, isActive: false, isConfigured: true, isWaiting: false)
            }
        }
        let foldersChanged = next.compactMap(\.folder) != entries.compactMap(\.folder)
        entries = next
        renderRows()
        if foldersChanged { refreshBranches() }
    }

    var hasFocus: Bool { view.hasFocus }

    func setHoverCovered(_ covered: Bool) { view.setHoverCovered(covered) }

    var focusedRow: SidebarRowID? { view.focusedRow }

    var focusedStop: SidebarFocusStop? { view.focusedStop }

    @discardableResult
    func focusRow(_ id: SidebarRowID) -> Bool { isShown && view.focusRow(id) }

    @discardableResult
    func focusStop(_ stop: SidebarFocusStop) -> Bool { isShown && view.focusStop(stop) }

    enum NewWorktreeRefusal: CaseIterable {
        case worktree, unconfigured, notARepo, agent

        var message: String {
            let chord = CommandCatalog.spec(for: .createWorktree).shortcut
            let picker = CommandCatalog.spec(for: .toggleRepoPicker).shortcut
            switch self {
            case .worktree: return "A worktree starts from its workspace.\nPress \(chord) on the workspace above it."
            case .unconfigured: return "This workspace isn't configured.\nSet one up with Add Workspace… in \(picker)."
            case .notARepo: return "This workspace isn't a git repository.\nWorktrees need a git repository."
            case .agent: return "Agents don't start worktrees.\nPress \(chord) on a workspace row."
            }
        }
    }

    var focusedWorktreeParent: SidebarRowID? {
        guard let row = view.focusedRow, let entry = entries.first(where: { $0.row == row }),
            Self.rowItem(entry).makesWorktrees
        else { return nil }
        return row
    }

    var focusedWorktreeRefusal: NewWorktreeRefusal? {
        if view.agentRowHasFocus { return .agent }
        guard let row = view.focusedRow, let entry = entries.first(where: { $0.row == row }),
            !Self.rowItem(entry).makesWorktrees
        else { return nil }
        switch entry.kind {
        case .worktree: return .worktree
        case .workspace where !entry.isConfigured: return .unconfigured
        case .workspace, .ghost: return .notARepo
        }
    }

    func focusActiveRow() {
        guard let active = entries.first(where: \.isActive) else { return }
        view.focusRow(active.row)
    }

    func refreshBranches() {
        GitRepoStatus.refresh(entries.compactMap(\.folder)) { [weak self] in self?.renderRows() }
    }

    private func renderRows() {
        view.render(entries.map(Self.rowItem))
        renderLead()
    }

    private func renderLead() {
        guard let active = entries.first(where: \.isActive) else { return }
        if case .worktree(let origin) = active.kind {
            lead.setWorkspaceName(
                origin.parent.title, worktree: active.folder.flatMap(GitRepoStatus.branch) ?? origin.name)
        } else {
            lead.setWorkspaceName(active.name)
        }
        applyLeadWidth()
    }

    // The slide animates this constant, so writing it mid-flight would snap the lead and the tab bar to the end.
    private func applyLeadWidth() {
        guard !isSliding, !isDocked else { return }
        leadWidth?.constant = lead.contentWidth
    }

    private static let worktreeSymbol = "arrow.triangle.branch"

    private static func rowItem(_ entry: Entry) -> SidebarRowItem {
        let branch = entry.folder.flatMap(GitRepoStatus.branch)
        switch entry.kind {
        case .workspace:
            let isRepo = entry.folder.flatMap(GitRepoStatus.known) == true
            return SidebarRowItem(
                id: entry.row, variant: .standard, name: entry.name, branch: branch, number: entry.number,
                isActive: entry.isActive, makesWorktrees: entry.isConfigured && isRepo, isWaiting: entry.isWaiting)
        case .worktree(let origin):
            return SidebarRowItem(
                id: entry.row, variant: .nested(symbol: worktreeSymbol), name: branch ?? origin.name,
                branch: nil, number: entry.number, isActive: entry.isActive, makesWorktrees: false,
                isWaiting: entry.isWaiting)
        case .ghost:
            return SidebarRowItem(
                id: entry.row, variant: .faint, name: entry.name, branch: nil, number: nil, isActive: false,
                makesWorktrees: true, isWaiting: false)
        }
    }

    func renderAgents(_ items: [SidebarAgentItem]) { view.renderAgents(items) }

    func setOpenModal(palette: Bool, settings: Bool) { footer.setOpenModal(palette: palette, settings: settings) }

    func setHiddenButtons(_ hidden: Set<ToolbarButton>) { footer.setHiddenButtons(hidden) }

    func shutdown() { edgeReveal.shutdown() }

    func reapplyTheme() {
        column.reapplyTheme()
        lead.reapplyTheme()
        toggleButton.reapplyTheme()
    }

    func reapplyChromeLayout() {
        sidebarTop?.constant = ChromeMetrics.topInset
        canvasOffset?.constant = canvasGap
        applyToggleLeading()
        column.reapplyCornerRadius()
    }

    var toggleButtonForTesting: IconButton { toggleButton }

    static func resetLastChoiceForTesting() { lastChoiceIsDocked = true }
}
