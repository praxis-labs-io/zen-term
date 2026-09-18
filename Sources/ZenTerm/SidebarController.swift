import AppKit
import TerminalKit

/// Docks and collapses one window's sidebar, and owns the edge the canvas, tool floats and tab bar start from.
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

    let view: SidebarView
    let lead: CollapsedSidebarLead
    private let edge = NSLayoutGuide()
    private(set) var isDocked = SidebarController.lastChoiceIsDocked
    private var edgeLeading: NSLayoutConstraint?
    private var leadWidth: NSLayoutConstraint?
    private var sidebarTop: NSLayoutConstraint?
    private var slideID = 0
    private var entries: [Entry] = []

    init(onPalette: @escaping () -> Void, onSettings: @escaping () -> Void, onToggle: @escaping () -> Void) {
        view = SidebarView(onPalette: onPalette, onSettings: onSettings, onToggle: onToggle)
        lead = CollapsedSidebarLead(onToggle: onToggle)
    }

    var canvasLeadingAnchor: NSLayoutXAxisAnchor { edge.leadingAnchor }

    func install(in container: NSView, besideTabBar tabBar: NSView) {
        container.addSubview(view)
        container.addSubview(lead)
        container.addLayoutGuide(edge)
        let edgeLeading = edge.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: edgeOffset)
        let leadWidth = lead.widthAnchor.constraint(equalToConstant: leadOffset)
        let sidebarTop = view.topAnchor.constraint(equalTo: container.topAnchor, constant: ChromeMetrics.topInset)
        self.edgeLeading = edgeLeading
        self.leadWidth = leadWidth
        self.sidebarTop = sidebarTop
        NSLayoutConstraint.activate([
            edgeLeading,
            edge.widthAnchor.constraint(equalToConstant: 0),
            edge.topAnchor.constraint(equalTo: container.topAnchor),
            edge.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            sidebarTop,
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            view.footer.centerYAnchor.constraint(equalTo: tabBar.centerYAnchor, constant: -TabBarView.bandNudge),
            lead.leadingAnchor.constraint(equalTo: edge.leadingAnchor),
            lead.centerYAnchor.constraint(equalTo: tabBar.centerYAnchor, constant: -TabBarView.bandNudge),
            leadWidth,
        ])
        settle()
    }

    private var edgeOffset: CGFloat { isDocked ? SidebarView.width : 0 }
    private var leadOffset: CGFloat { isDocked ? 0 : lead.contentWidth }

    /// Holds `surfaces`' grids for the slide, so they reflow once. Snaps under reduced motion, as a drawer does.
    func toggle(holding surfaces: [TerminalSurface], in root: NSView) {
        guard let edgeLeading, let leadWidth else { return }
        isDocked.toggle()
        Self.lastChoiceIsDocked = isDocked
        view.isHidden = false
        lead.isHidden = false
        slideID &+= 1
        guard !Motion.isReduceMotionEnabled() else {
            edgeLeading.constant = edgeOffset
            leadWidth.constant = leadOffset
            settle()
            root.layoutSubtreeIfNeeded()
            return
        }
        let id = slideID
        Motion.drawerSlide(
            panel: view, opening: isDocked, parkOffset: CGVector(dx: -SidebarView.width, dy: 0),
            animate: [(edgeLeading, edgeOffset), (leadWidth, leadOffset)], in: root,
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

    func setOpenModal(palette: Bool, settings: Bool) { view.setOpenModal(palette: palette, settings: settings) }

    func reapplyTheme() {
        view.reapplyTheme()
        lead.reapplyTheme()
    }

    func reapplyChromeLayout() { sidebarTop?.constant = ChromeMetrics.topInset }

    var edgeOffsetForTesting: CGFloat { edgeLeading?.constant ?? -1 }

    static func resetLastChoiceForTesting() { lastChoiceIsDocked = true }
}
