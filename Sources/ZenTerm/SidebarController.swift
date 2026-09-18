import AppKit
import TerminalKit

/// Docks and collapses one window's sidebar, and owns the edges the canvas, tool floats and tab bar start from.
@MainActor
final class SidebarController {
    // Per launch, not persisted: a new window opens the way the last toggle left one.
    private static var lastChoiceIsDocked = true

    private struct Entry {
        let id: WorkspaceID
        let name: String
        let folder: URL
        let isActive: Bool
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
    private var sidebarTop: NSLayoutConstraint?
    private var slideID = 0
    private var entries: [Entry] = []

    init(onPalette: @escaping () -> Void, onSettings: @escaping () -> Void, onToggle: @escaping () -> Void) {
        view = SidebarView()
        footer = SidebarFooter(onPalette: onPalette, onSettings: onSettings)
        toggleButton = SidebarFooter.button("sidebar.left", "Toggle sidebar", .toggleSidebar, onToggle)
        lead = CollapsedSidebarLead(
            leadingInset: Self.toggleInset + SidebarFooter.buttonSize.width + Self.leadNameGap)
    }

    var canvasLeadingAnchor: NSLayoutXAxisAnchor { canvasEdge.leadingAnchor }

    func install(in container: NSView, besideTabBar tabBar: NSView) {
        container.addSubview(view)
        container.addSubview(lead)
        container.addSubview(footer)
        container.addSubview(toggleButton)
        container.addLayoutGuide(edge)
        container.addLayoutGuide(canvasEdge)
        let edgeLeading = edge.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: edgeOffset)
        let canvasOffset = canvasEdge.leadingAnchor.constraint(equalTo: edge.leadingAnchor, constant: canvasGap)
        let leadWidth = lead.widthAnchor.constraint(equalToConstant: leadOffset)
        let sidebarTop = view.topAnchor.constraint(equalTo: container.topAnchor, constant: ChromeMetrics.topInset)
        self.edgeLeading = edgeLeading
        self.canvasOffset = canvasOffset
        self.leadWidth = leadWidth
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
            toggleButton.centerYAnchor.constraint(equalTo: tabBar.centerYAnchor),
            footer.leadingAnchor.constraint(equalTo: toggleButton.trailingAnchor, constant: SidebarFooter.spacing),
            footer.centerYAnchor.constraint(equalTo: toggleButton.centerYAnchor),
            lead.leadingAnchor.constraint(equalTo: edge.leadingAnchor),
            lead.centerYAnchor.constraint(equalTo: tabBar.centerYAnchor),
            leadWidth,
        ])
        settle()
    }

    private var edgeOffset: CGFloat { isDocked ? SidebarView.width : 0 }
    private var leadOffset: CGFloat { isDocked ? 0 : lead.contentWidth }
    // The canvas insets itself by window-gutter; docked, it sits one pane-gap from the sidebar, as from a drawer.
    private var canvasGap: CGFloat { isDocked ? ChromeMetrics.panelGap - ChromeMetrics.windowGutter : 0 }

    /// Holds `surfaces`' grids for the slide, so they reflow once. Snaps under reduced motion, as a drawer does.
    func toggle(holding surfaces: [TerminalSurface], in root: NSView) {
        guard let edgeLeading, let canvasOffset, let leadWidth else { return }
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
            settle()
            root.layoutSubtreeIfNeeded()
            return
        }
        let id = slideID
        Motion.drawerSlide(
            panel: view, opening: isDocked, parkOffset: CGVector(dx: -SidebarView.width, dy: 0),
            animate: [(edgeLeading, edgeOffset), (canvasOffset, canvasGap), (leadWidth, leadOffset)], in: root,
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

    func render(workspaces: [WorkspaceController], active: WorkspaceController) {
        let next = workspaces.map {
            Entry(id: $0.id, name: $0.name, folder: $0.folder, isActive: $0 === active)
        }
        let foldersChanged = next.map(\.folder) != entries.map(\.folder)
        entries = next
        lead.setWorkspaceName(active.name)
        if !isDocked { leadWidth?.constant = lead.contentWidth }
        renderRows()
        if foldersChanged { refreshBranches() }
    }

    /// Re-reads each workspace's branch off the main thread; the rows update when the answers land.
    func refreshBranches() {
        GitRepoStatus.refresh(entries.map(\.folder)) { [weak self] in self?.renderRows() }
    }

    private func renderRows() {
        view.render(
            entries.map {
                SidebarRowItem(id: $0.id, name: $0.name, branch: GitRepoStatus.branch($0.folder), isActive: $0.isActive)
            })
    }

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
