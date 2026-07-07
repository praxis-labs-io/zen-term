import AppKit
import PaneKit
import TerminalKit

/// Owns the pane tree, the surface registry, and per-leaf cwd. Renders the tree
/// into `canvasView`, reusing each leaf's surface across restructures. Acts as the
/// surface delegate for every pane.
final class PaneCanvasController: NSObject {
    let canvasView = NSView()

    private var tree: PaneTree
    private let registry: PaneSurfaceRegistry
    private var cwdByLeaf: [PaneID: URL] = [:]
    private var hostByLeaf: [PaneID: PanelHostView] = [:]
    private var nextID = 1

    private static let canvasColor = NSColor(srgbRed: 0x23 / 255.0, green: 0x21 / 255.0, blue: 0x36 / 255.0, alpha: 1)
    private static let minSplitExtent: CGFloat = 240

    /// Invoked when the last remaining pane's shell exits on its own. (A manual ⌘W
    /// on the last pane is handled separately: `closeFocused()` returns false and the
    /// chrome closes the window directly.)
    var onLastPaneClosed: (() -> Void)?

    /// Fired when the tab's title may have changed — the focused pane's cwd
    /// changed, or focus moved to a different pane.
    var onTitleChanged: (() -> Void)?

    /// The focused pane's cwd, for new-tab / new-window inheritance. Prefers the live
    /// process cwd over the last OSC-reported one so inheritance works without OSC 7.
    var focusedCWD: URL? {
        registry.surface(for: tree.focusedLeaf)?.currentDirectory ?? cwdByLeaf[tree.focusedLeaf]
    }

    /// The tab's display title: the focused pane's cwd basename (`~` for home),
    /// resolved live from the shell process. Falls back to the terminal (OSC) title
    /// if a cwd can't be read, then a generic label.
    var title: String {
        let surface = registry.surface(for: tree.focusedLeaf)
        if let cwd = surface?.currentDirectory ?? cwdByLeaf[tree.focusedLeaf] {
            if cwd.path == Self.homePath { return "~" }
            let name = cwd.lastPathComponent
            if !name.isEmpty && name != "/" { return name }
        }
        if let osc = surface?.title {
            let trimmed = osc.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return "shell"
    }

    private static let homePath = FileManager.default.homeDirectoryForCurrentUser.path

    init(initialCWD: URL? = nil) {
        let firstLeaf = PaneID(1)
        self.tree = PaneTree(singleLeaf: firstLeaf)
        self.registry = PaneSurfaceRegistry(makeSurface: TerminalSurfaceFactory.make)
        super.init()
        nextID = 2
        if let initialCWD { cwdByLeaf[firstLeaf] = initialCWD }
        canvasView.wantsLayer = true
        canvasView.layer?.backgroundColor = Self.canvasColor.cgColor
    }

    private func mintPaneID() -> PaneID { defer { nextID += 1 }; return PaneID(nextID) }
    private func mintSplitID() -> SplitID { defer { nextID += 1 }; return SplitID(nextID) }

    /// Boots the first pane and renders.
    func start() {
        reconcileAndRender()
        focusFrontmost()
    }

    /// Diffs the registry against the current tree, creates/terminates surfaces,
    /// starts new ones (delegate + inherited cwd), then rebuilds the view tree.
    private func reconcileAndRender() {
        let diff = paneDiff(from: Array(registry.ids), to: tree.leafIDs)
        let created = registry.apply(diff)
        for (id, surface) in created {
            surface.delegate = self
            // Each created leaf starts with the cwd pre-seeded for it (nil → default
            // for the first pane; a split seeds the new leaf with its parent's cwd).
            surface.start(TerminalSurfaceConfig(workingDirectory: cwdByLeaf[id], theme: Theme.rosePineMoon))
        }
        for id in diff.removed { cwdByLeaf[id] = nil; hostByLeaf[id] = nil }
        rebuildViews()
    }

    private func rebuildViews() {
        canvasView.subviews.forEach { $0.removeFromSuperview() }
        hostByLeaf.removeAll(keepingCapacity: true)

        let root = SplitContainerView(node: tree.root, leafView: { [weak self] id in
            self?.hostView(for: id) ?? NSView()
        })
        // SplitContainerView.init already sets translatesAutoresizingMaskIntoConstraints=false.
        // `canvasView` fills exactly the tile `TabController` gives it — the outer
        // 12pt gutter + 36pt top inset (clearing the window's traffic lights) live in
        // `TabController`'s content-rect tiling, not here.
        canvasView.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: canvasView.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: canvasView.trailingAnchor),
            root.topAnchor.constraint(equalTo: canvasView.topAnchor),
            root.bottomAnchor.constraint(equalTo: canvasView.bottomAnchor),
        ])
        updateHalo()
    }

    private func hostView(for id: PaneID) -> NSView {
        guard let surface = registry.surface(for: id) else { return NSView() }
        let host = PanelHostView(content: surface.view,
                                 background: Theme.rosePineMoon.background.nsColor,
                                 meta: nil,
                                 onFocusRequest: { [weak self] in
            self?.focus(id)
        })
        hostByLeaf[id] = host
        return host
    }

    private func updateHalo() {
        for (id, host) in hostByLeaf { host.isFocused = (id == tree.focusedLeaf) }
    }

    // Focus routing (fleshed out in Task 10).
    func focus(_ id: PaneID) {
        guard tree.contains(id) else { return }
        tree.focusedLeaf = id
        updateHalo()
        onTitleChanged?()
        registry.surface(for: id)?.focus()
    }

    private func focusFrontmost() { focus(tree.focusedLeaf) }

    /// Restore focus + halo to this tab's focused pane (used when its tab is
    /// re-mounted after a switch).
    func focusActivePane() { focus(tree.focusedLeaf) }

    /// Move focus to the nearest pane in `direction`, using on-screen frames.
    func navigate(_ direction: Direction) {
        guard hostByLeaf.count > 1 else { return }
        // AppKit is y-up (higher on screen = larger y), but the scorer treats `.up`
        // as decreasing y (top-left origin). Flip each frame into that y-down space
        // (`h - maxY`) so visual-up maps to the scorer's `.up`.
        let h = canvasView.bounds.height
        var frames: [PaneID: CGRect] = [:]
        for (id, host) in hostByLeaf {
            let f = host.convert(host.bounds, to: canvasView)
            frames[id] = CGRect(x: f.minX, y: h - f.maxY, width: f.width, height: f.height)
        }
        if let target = nearestLeaf(from: tree.focusedLeaf, frames: frames, direction: direction) {
            focus(target)
        }
    }

    /// Split the focused pane along `axis`, unless it is too small to halve usefully.
    func split(_ axis: SplitAxis) {
        guard let host = hostByLeaf[tree.focusedLeaf] else { return }
        let size = host.bounds.size
        let extent = (axis == .vertical) ? size.width : size.height
        guard extent >= Self.minSplitExtent else { NSSound.beep(); return }

        let source = tree.focusedLeaf
        let newLeaf = mintPaneID()
        // inherit the focused pane's live cwd (falls back to last OSC-reported)
        cwdByLeaf[newLeaf] = registry.surface(for: source)?.currentDirectory ?? cwdByLeaf[source]
        tree = tree.splitting(source, axis: axis, newLeaf: newLeaf, newSplit: mintSplitID())
        reconcileAndRender()
        registry.surface(for: tree.focusedLeaf)?.focus()
    }

    /// Close the focused pane. Returns false when it was the last pane (caller closes the window).
    @discardableResult
    func closeFocused() -> Bool {
        guard let next = tree.closing(tree.focusedLeaf) else { return false }
        tree = next
        reconcileAndRender()
        registry.surface(for: tree.focusedLeaf)?.focus()
        return true
    }

    @objc func copyFromSurface(_ sender: Any?) {
        guard let text = registry.surface(for: tree.focusedLeaf)?.copySelection(), !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc func pasteToSurface(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        registry.surface(for: tree.focusedLeaf)?.paste(text)
    }

    /// Terminates every pane's shell and detaches its view. Called when the whole
    /// tab is discarded (its controller is dropped), so no shell leaks as a zombie.
    func shutdown() {
        registry.terminateAll()
        canvasView.subviews.forEach { $0.removeFromSuperview() }
        hostByLeaf.removeAll()
    }
}

extension PaneCanvasController: TerminalSurfaceDelegate {
    func surface(_ s: TerminalSurface, cwdDidChange url: URL) {
        guard let id = leafID(of: s) else { return }
        cwdByLeaf[id] = url
        if id == tree.focusedLeaf { onTitleChanged?() }
    }
    func surface(_ s: TerminalSurface, titleDidChange title: String) {
        guard let id = leafID(of: s), id == tree.focusedLeaf else { return }
        onTitleChanged?()
    }
    func surfaceDidExit(_ s: TerminalSurface, code: Int32?) {
        guard let id = leafID(of: s) else { return }
        guard let next = tree.closing(id) else {
            onLastPaneClosed?()      // last pane's shell exited → close window
            return
        }
        tree = next
        reconcileAndRender()
        registry.surface(for: tree.focusedLeaf)?.focus()
    }

    private func leafID(of surface: TerminalSurface) -> PaneID? {
        registry.ids.first { registry.surface(for: $0) === surface }
    }
}
