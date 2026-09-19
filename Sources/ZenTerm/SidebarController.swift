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
    private static let leadNameGap: CGFloat = 6

    let view: SidebarView
    let footer: SidebarFooter
    let lead: CollapsedSidebarLead
    private let toggleButton: IconButton
    private let edge = NSLayoutGuide()
    private let canvasEdge = NSLayoutGuide()
    private(set) var isDocked = SidebarController.lastChoiceIsDocked
    private var edgeLeading: NSLayoutConstraint?
    private var canvasOffset: NSLayoutConstraint?
    private var leadWidth: NSLayoutConstraint?
    private var tabBarLeading: NSLayoutConstraint?
    private var sidebarTop: NSLayoutConstraint?
    private var slideID = 0
    private var entries: [Entry] = []
    var onLeave: () -> Void = {}
    var onJump: (SurfaceID) -> Void = { _ in }

    init(
        onPalette: @escaping () -> Void, onSettings: @escaping () -> Void, onToggle: @escaping () -> Void,
        onActivate: @escaping (SidebarRowID) -> Void, onNewWorktree: @escaping (SidebarRowID) -> Void,
        onCloseWorkspace: @escaping (WorkspaceID) -> Void, onAdd: @escaping () -> Void
    ) {
        view = SidebarView(
            onActivate: onActivate, onNewWorktree: onNewWorktree, onCloseWorkspace: onCloseWorkspace, onAdd: onAdd)
        footer = SidebarFooter(onPalette: onPalette, onSettings: onSettings)
        toggleButton = SidebarFooter.button("sidebar.left", "Toggle sidebar", .toggleSidebar, onToggle)
        lead = CollapsedSidebarLead(
            leadingInset: Self.toggleInset + SidebarFooter.buttonSize.width + Self.leadNameGap)
        view.onLeave = { [weak self] in self?.onLeave() }
        view.onJump = { [weak self] in self?.onJump($0) }
    }

    var edgeAnchor: NSLayoutXAxisAnchor { edge.leadingAnchor }
    var canvasLeadingAnchor: NSLayoutXAxisAnchor { canvasEdge.leadingAnchor }

    func install(in container: NSView, besideTabBar tabBar: TabBarView) {
        container.addSubview(view)
        container.addSubview(lead)
        container.addSubview(footer)
        container.addSubview(toggleButton)
        container.addLayoutGuide(edge)
        container.addLayoutGuide(canvasEdge)
        let edgeLeading = edge.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: edgeOffset)
        let canvasOffset = canvasEdge.leadingAnchor.constraint(equalTo: edge.leadingAnchor, constant: canvasGap)
        let leadWidth = lead.widthAnchor.constraint(equalToConstant: leadOffset)
        let tabBarLeading = tabBar.leadingAnchor.constraint(equalTo: lead.trailingAnchor, constant: tabBarPull)
        let sidebarTop = view.topAnchor.constraint(equalTo: container.topAnchor, constant: ChromeMetrics.topInset)
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
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            sidebarTop,
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            toggleButton.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Self.toggleInset),
            toggleButton.centerYAnchor.constraint(equalTo: tabBar.chipBandCenterYAnchor),
            footer.leadingAnchor.constraint(equalTo: toggleButton.trailingAnchor, constant: SidebarFooter.spacing),
            footer.centerYAnchor.constraint(equalTo: toggleButton.centerYAnchor),
            lead.leadingAnchor.constraint(equalTo: edge.leadingAnchor),
            lead.centerYAnchor.constraint(equalTo: tabBar.chipBandCenterYAnchor),
            leadWidth,
            tabBarLeading,
        ])
        view.limitContent(above: toggleButton.topAnchor)
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
        guard let edgeLeading, let canvasOffset, let leadWidth, let tabBarLeading else { return }
        isDocked.toggle()
        Self.lastChoiceIsDocked = isDocked
        view.isHidden = false
        lead.isHidden = false
        footer.isHidden = false
        Motion.fade(footer, to: isDocked ? 1 : 0, duration: Motion.pageSlideDuration)
        slideID &+= 1
        guard !Motion.isReduceMotionEnabled() else {
            edgeLeading.constant = edgeOffset
            canvasOffset.constant = canvasGap
            leadWidth.constant = leadOffset
            tabBarLeading.constant = tabBarPull
            settle()
            root.layoutSubtreeIfNeeded()
            return
        }
        let id = slideID
        Motion.drawerSlide(
            panel: view, opening: isDocked, parkOffset: CGVector(dx: -SidebarView.width, dy: 0),
            animate: [
                (edgeLeading, edgeOffset), (canvasOffset, canvasGap), (leadWidth, leadOffset),
                (tabBarLeading, tabBarPull),
            ], in: root,
            beforeSlide: { surfaces.forEach { $0.setSizeSyncSuspended(true) } }
        ) { [weak self] in
            surfaces.forEach { $0.setSizeSyncSuspended(false) }
            guard let self, self.slideID == id else { return }
            self.view.layer?.transform = CATransform3DIdentity
            self.settle()
        }
    }

    private func settle() {
        view.isHidden = !isDocked
        footer.isHidden = !isDocked
        footer.layer?.opacity = isDocked ? 1 : 0
        lead.isHidden = isDocked
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

    @discardableResult
    func focusRow(_ id: SidebarRowID) -> Bool { isDocked && view.focusRow(id) }

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
        if !isDocked { leadWidth?.constant = lead.contentWidth }
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

    func reapplyTheme() {
        view.reapplyTheme()
        footer.reapplyTheme()
        lead.reapplyTheme()
        toggleButton.reapplyTheme()
    }

    func reapplyChromeLayout() {
        sidebarTop?.constant = ChromeMetrics.topInset
        canvasOffset?.constant = canvasGap
    }

    var toggleButtonForTesting: IconButton { toggleButton }

    static func resetLastChoiceForTesting() { lastChoiceIsDocked = true }
}
