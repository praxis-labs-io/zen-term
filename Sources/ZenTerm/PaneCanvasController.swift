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
    private var hostByLeaf: [PaneID: PaneHostView] = [:]
    private var nextID = 1

    private static let canvasColor = NSColor(srgbRed: 0x23 / 255.0, green: 0x21 / 255.0, blue: 0x36 / 255.0, alpha: 1)

    override init() {
        let firstLeaf = PaneID(1)
        self.tree = PaneTree(singleLeaf: firstLeaf)
        self.registry = PaneSurfaceRegistry(makeSurface: TerminalSurfaceFactory.make)
        super.init()
        nextID = 2
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
            surface.start(TerminalSurfaceConfig(workingDirectory: cwdByLeaf[id]))
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
        // 12pt gutter around the whole canvas (matches Epic 0's outer inset).
        canvasView.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: canvasView.leadingAnchor, constant: 12),
            root.trailingAnchor.constraint(equalTo: canvasView.trailingAnchor, constant: -12),
            root.topAnchor.constraint(equalTo: canvasView.topAnchor, constant: 12),
            root.bottomAnchor.constraint(equalTo: canvasView.bottomAnchor, constant: -12),
        ])
        updateHalo()
    }

    private func hostView(for id: PaneID) -> NSView {
        guard let surface = registry.surface(for: id) else { return NSView() }
        let host = PaneHostView(paneID: id, content: surface.view, onFocusRequest: { [weak self] pid in
            self?.focus(pid)
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
        registry.surface(for: id)?.focus()
    }

    private func focusFrontmost() { focus(tree.focusedLeaf) }
}

extension PaneCanvasController: TerminalSurfaceDelegate {
    func surface(_ s: TerminalSurface, cwdDidChange url: URL) {
        if let id = leafID(of: s) { cwdByLeaf[id] = url }
    }
    func surfaceDidExit(_ s: TerminalSurface, code: Int32?) {
        // Handled fully in Task 11 (close that leaf); for now, no-op keeps Epic-0 parity.
    }

    private func leafID(of surface: TerminalSurface) -> PaneID? {
        registry.ids.first { registry.surface(for: $0) === surface }
    }
}
