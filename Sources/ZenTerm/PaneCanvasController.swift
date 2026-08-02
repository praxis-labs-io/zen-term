import AppKit
import AppLog
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
    /// The exact config each leaf was started with, retained so a failed surface can be
    /// retried by replaying it. Cleared when the leaf is torn down.
    private var launchByLeaf: [PaneID: TerminalSurfaceConfig] = [:]
    /// The `NavRegistry` token minted for each live leaf, exported to its shell as
    /// `$ZEN_PANE` and used to address the pane over the nav socket. Cleared (and
    /// unregistered) when the leaf's surface is torn down.
    private var tokenByLeaf: [PaneID: Int] = [:]
    /// A one-shot startup command per leaf (the `⌘P` workspace preset seeds the first
    /// leaf with `nvim`). Consumed when the leaf's surface is first started; splits
    /// never inherit it, so a split of an nvim pane is a plain shell.
    private var startupCommandByLeaf: [PaneID: String] = [:]
    /// A workspace recipe's environment, injected into every pane of this tab (the first pane
    /// and its splits). Empty for a plain `⌘t` tab.
    private let workspaceEnv: [String: String]
    private var nextID = 1

    /// The single leaf rendered full-canvas when zoomed, or nil when the whole tree
    /// renders normally. Zoom only swaps what `rebuildViews()` puts at the root —
    /// the tree, registry, and every surface are untouched, so unzooming restores
    /// the split layout with no restart.
    private var zoomedLeaf: PaneID?
    var isZoomed: Bool { zoomedLeaf != nil }

    /// Each split's rendered container view, refreshed every `rebuildViews()`. Read at
    /// resize time so a nudge can be clamped to keep both sides ≥ `minSplitExtent` in
    /// pixels, not just a bare ratio — and retargeted in place via `setRatio` so an
    /// ⌥-arrow nudge never rebuilds the tree.
    private var splitViewByID: [SplitID: SplitContainerView] = [:]

    /// Close-out overlays currently fading (a just-closed pane dissolving over the collapsed tree),
    /// kept out of `rebuildViews`' teardown so a concurrent reconcile doesn't snap them away.
    private var dissolvingHosts: [NSView] = []

    /// Whether panes may show their focus halo. `TabController` sets this to false
    /// when a drawer holds unified focus, so exactly one panel is haloed across the
    /// whole tab.
    private var panesHoldFocus = true

    private static let minSplitExtent: CGFloat = 240
    /// One ⌥-arrow nudge, as a fraction of the enclosing split; ratios never pass
    /// `minSplitRatio` from either end.
    private static let resizeStep: Double = 0.04
    private static let minSplitRatio: Double = 0.12

    /// Invoked when the last remaining pane's shell exits on its own. (A manual ⌘W
    /// on the last pane is handled separately: `closeFocused()` returns false and the
    /// chrome closes the window directly.)
    var onLastPaneClosed: (() -> Void)?

    /// Fired with the leaf ids that vanished on the last reconcile (a ⌘W close or a shell
    /// exiting on its own) — the single choke point for pane removal. `TabController` uses it
    /// to prune per-pane focus memory so it can't grow unbounded.
    var onPanesRemoved: (([PaneID]) -> Void)?

    /// Fired when the tab's title may have changed — the focused pane's cwd
    /// changed, or focus moved to a different pane.
    var onTitleChanged: (() -> Void)?

    /// Fired at the end of `focus(_:)` — lets `TabController` know a pane has
    /// (re)gained focus, so it can reassert unified panel focus (halo, copy/paste
    /// routing) onto the pane canvas.
    var onFocusChanged: (() -> Void)?

    /// A pane's scroll position moved. Carries the surface so a consumer can match it against
    /// the one it cares about (ZEN-330).
    var onScrollPosition: ((TerminalSurface, TerminalScrollPosition) -> Void)?

    /// Fired when a socket `focus` command names one of this canvas's panes (an nvim split
    /// at its edge handing off). `TabController` routes it into its unified `navigate(_:)`.
    var onSocketFocus: ((Direction) -> Void)?

    /// Fired when any pane's surface posts a desktop notification (OSC 777) — the tab-level,
    /// message-bearing "needs attention" signal (e.g. an agent asking permission). `TabController`
    /// relays it up.
    var onNotification: ((TerminalNotification) -> Void)?

    /// Fired when shell integration reports that a foreground command completed in any pane.
    var onCommandFinished: ((TerminalCommandResult) -> Void)?

    /// Fired when zoom ends on its own because the zoomed leaf disappeared (its shell
    /// exited) — the owning `TabController` clears its `zoomedPanel` so zoom state and
    /// panel visibility stay in sync.
    var onZoomEnded: (() -> Void)?

    /// Fired when a pane's surface fails to start (its backend couldn't create the terminal).
    /// Hands the chrome the retry/close actions; this controller keeps the mechanics (retry
    /// replays the stored launch on the same surface, close drops the dead leaf).
    var onSurfaceStartFailed: ((_ retry: @escaping () -> Void, _ close: @escaping () -> Void) -> Void)?

    /// Drops the zoom if the zoomed leaf is no longer in the tree, notifying the owner.
    private func clearZoomIfLeafGone() {
        if let z = zoomedLeaf, !tree.leafIDs.contains(z) {
            zoomedLeaf = nil
            onZoomEnded?()
        }
    }

    /// The focused pane's cwd, for new-tab / new-window inheritance. Prefers the live
    /// process cwd over the last OSC-reported one so inheritance works without OSC 7.
    var focusedCWD: URL? {
        registry.surface(for: tree.focusedLeaf)?.currentDirectory ?? cwdByLeaf[tree.focusedLeaf]
    }

    /// Number of leaves (panes) in the tab's canvas. `1` means ⌘W closes the tab.
    var paneCount: Int { tree.leafIDs.count }

    /// Every live pane surface in this canvas, for a full config-change re-theme pass.
    var allSurfaces: [TerminalSurface] { registry.allSurfaces }

    /// Every pane in the tree's own order, so a picker can number them the way they read on screen
    /// (`allSurfaces` comes off a dictionary and has no order at all).
    var orderedLeafIDs: [PaneID] { tree.leafIDs }

    /// The surface behind a pane id, for a caller that already knows which pane it wants (the diff
    /// viewer's send target). Nil for an id with no live surface.
    func surface(for id: PaneID) -> TerminalSurface? { registry.surface(for: id) }

    /// The focused pane as scroll mode needs it: the terminal to drive, and the panel to hang
    /// its indicator on.
    var focusedScrollTarget: (surface: TerminalSurface, panel: PanelHostView)? {
        guard let surface = registry.surface(for: tree.focusedLeaf),
            let panel = hostByLeaf[tree.focusedLeaf]
        else { return nil }
        return (surface, panel)
    }

    /// Whether the focused pane's shell has live work (busy). False when the
    /// surface hasn't started or the backend can't tell.
    var focusedPaneIsBusy: Bool {
        registry.surface(for: tree.focusedLeaf)?.isBusy ?? false
    }

    /// The `$ZEN_PANE` token of the focused pane, or nil before its surface has started.
    var focusedPaneToken: Int? { tokenByLeaf[tree.focusedLeaf] }

    /// Whether the focused pane is running nvim (advertised over the nav socket). Read by
    /// the key pass-through guard so `Ctrl-hjkl` reaches nvim instead of moving pane focus.
    var focusedPaneIsVim: Bool {
        guard let token = focusedPaneToken else { return false }
        return NavRegistry.shared.isVim(token: token)
    }

    /// The tab's display title: the focused pane's cwd basename (`~` for home),
    /// resolved live from the shell process. Falls back to the terminal (OSC) title
    /// if a cwd can't be read, then a generic label.
    var title: String {
        let surface = registry.surface(for: tree.focusedLeaf)
        if let cwd = surface?.currentDirectory ?? cwdByLeaf[tree.focusedLeaf] {
            if cwd.path == PathDisplay.homePath { return "~" }
            let name = cwd.lastPathComponent
            if !name.isEmpty && name != "/" { return name }
        }
        if let osc = surface?.title {
            let trimmed = osc.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return "shell"
    }

    init(
        initialCWD: URL? = nil, initialCommand: String? = nil, env: [String: String] = [:],
        makeSurface: @escaping () -> TerminalSurface = TerminalSurfaceFactory.make
    ) {
        let firstLeaf = PaneID(1)
        self.tree = PaneTree(singleLeaf: firstLeaf)
        self.registry = PaneSurfaceRegistry(makeSurface: makeSurface)
        self.workspaceEnv = env
        super.init()
        nextID = 2
        if let initialCWD { cwdByLeaf[firstLeaf] = initialCWD }
        if let initialCommand { startupCommandByLeaf[firstLeaf] = initialCommand }
        // Transparent canvas: only the panes (opaque PanelHostView clips) paint. The pane
        // gutters and the window inset fall through to the tinted blur backdrop.
        canvasView.wantsLayer = true
        canvasView.layer?.backgroundColor = NSColor.clear.cgColor
    }

    private func mintPaneID() -> PaneID { defer { nextID += 1 }; return PaneID(nextID) }
    private func mintSplitID() -> SplitID { defer { nextID += 1 }; return SplitID(nextID) }

    /// Mint and record a nav token for a freshly-created leaf, registering its focus-move
    /// closure so a socket `focus` from that pane routes into the tab's `navigate(_:)`.
    private func registerNavToken(for id: PaneID) -> Int {
        let token = NavRegistry.shared.mintToken()
        tokenByLeaf[id] = token
        NavRegistry.shared.register(token: token) { [weak self] dir in
            // Only the focused pane hands off. nvim emits `focus` on a keypress, which it can
            // only receive while focused, so the sender is the focused pane in the normal flow;
            // dropping a mismatch ignores a stale or background command that would otherwise
            // navigate from the wrong origin.
            guard let self, self.focusedPaneToken == token else { return }
            self.onSocketFocus?(dir)
        }
        return token
    }

    /// The pane's launch environment: the tab's workspace env plus the nav-socket path and
    /// this pane's token, so the nvim plugin inside can address itself over the socket.
    private func navEnv(token: Int) -> [String: String] {
        NavSocketServer.env(base: workspaceEnv, token: token)
    }

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
            let token = registerNavToken(for: id)
            // Each created leaf starts with the cwd pre-seeded for it (nil → default
            // for the first pane; a split seeds the new leaf with its parent's cwd). A
            // seeded startup command (workspace preset) runs a program that drops back to
            // a shell; consume it so it never re-runs.
            let launch: TerminalSurfaceConfig
            if let cmd = startupCommandByLeaf.removeValue(forKey: id) {
                launch = ShellLaunch.program(cmd, cwd: cwdByLeaf[id], env: navEnv(token: token))
            } else {
                launch = ShellLaunch.shell(cwd: cwdByLeaf[id], env: navEnv(token: token))
            }
            launchByLeaf[id] = launch
            surface.start(launch)
            Log.info("surface started (pane \(id))", category: .surface)
        }
        for id in diff.removed {
            Log.info("surface stopped (pane \(id))", category: .surface)
            cwdByLeaf[id] = nil
            hostByLeaf[id] = nil
            launchByLeaf[id] = nil
            if let token = tokenByLeaf.removeValue(forKey: id) { NavRegistry.shared.unregister(token: token) }
        }
        if !diff.removed.isEmpty { onPanesRemoved?(diff.removed) }
        rebuildViews()
    }

    private func rebuildViews() {
        // Keep any in-flight close-out dissolve overlays (re-fronted below); drop the previous tree.
        for subview in canvasView.subviews where !dissolvingHosts.contains(where: { $0 === subview }) {
            subview.removeFromSuperview()
        }
        // `hostByLeaf` survives the rebuild: retained leaves keep their PanelHostView (and
        // its constraints to `content`), so a restructure only reparents hosts instead of
        // rebuilding the pane chrome. Removed leaves were already pruned in reconcile.
        splitViewByID.removeAll(keepingCapacity: true)

        let root: NSView
        if let zoomedLeaf, tree.leafIDs.contains(zoomedLeaf) {
            root = hostView(for: zoomedLeaf)
            root.translatesAutoresizingMaskIntoConstraints = false
        } else {
            root = SplitContainerView(
                node: tree.root,
                register: { [weak self] id, v in self?.splitViewByID[id] = v },
                leafView: { [weak self] id in
                    self?.hostView(for: id) ?? NSView()
                })
        }
        // SplitContainerView.init (and PanelHostView) already set
        // translatesAutoresizingMaskIntoConstraints=false. `canvasView` fills exactly
        // the tile `TabController` gives it — the outer 12pt gutter + 36pt top inset
        // (clearing the window's traffic lights) live in `TabController`'s
        // content-rect tiling, not here.
        canvasView.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: canvasView.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: canvasView.trailingAnchor),
            root.topAnchor.constraint(equalTo: canvasView.topAnchor),
            root.bottomAnchor.constraint(equalTo: canvasView.bottomAnchor),
        ])
        dissolvingHosts.forEach { canvasView.addSubview($0) }  // keep the fade on top of the rebuilt tree
        updateHalo()
    }

    private func hostView(for id: PaneID) -> NSView {
        if let cached = hostByLeaf[id] { return cached }
        guard let surface = registry.surface(for: id) else { return NSView() }
        let host = PanelHostView(
            content: surface.view,
            meta: nil,
            zoomMeta: PanelMeta(title: "Terminal pane: Focus Mode", action: .toggleZoom),
            onFocusRequest: { [weak self] in
                self?.focus(id)
            })
        hostByLeaf[id] = host
        return host
    }

    /// Test hook: the live host per leaf, for asserting reuse across restructures (ZEN-54).
    var hostsForTesting: [PaneID: PanelHostView] { hostByLeaf }

    private func updateHalo() {
        for (id, host) in hostByLeaf {
            let focused = panesHoldFocus && (id == tree.focusedLeaf)
            host.isFocused = focused
            host.isZoomed = (id == zoomedLeaf)
            // Drive the surface's cursor focus explicitly — the AppKit responder chain alone
            // leaves stale blinking cursors on background panes after rapid splits.
            registry.surface(for: id)?.setFocused(focused && focusedSurfaceRendersFocused)
        }
    }

    /// Whether the focused pane's surface renders focused. Stored rather than pushed once, because
    /// `updateHalo` is the other writer of that same state and runs on every restructure: a mode
    /// that only pushed would have its unfocused render undone by the next reconcile.
    private var focusedSurfaceRendersFocused = true

    /// Render the focused pane's surface as focused or not, **without moving focus**. For a mode
    /// that holds the keyboard over a pane the chrome still considers focused.
    func setFocusedSurfaceRendersFocused(_ focused: Bool) {
        focusedSurfaceRendersFocused = focused
        updateHalo()
    }

    /// Re-apply the live pane border / focus-halo colors to every built pane after a config
    /// change — no relaunch, no restructure.
    func reapplyChromeColors() {
        for host in hostByLeaf.values { host.reapplyTheme() }
    }

    /// Re-apply the live `pane-gap` to every built split after a config change — no relaunch, no
    /// restructure. Sibling to `reapplyChromeColors()` (layout only). A split bakes its gutter in
    /// at construction, so without this the gap between panes needed a relaunch while every other
    /// Layout knob applied live.
    func reapplyChromeLayout() {
        for split in splitViewByID.values { split.setGutter(ChromeMetrics.panelGap) }
    }

    /// Render the focused leaf full-canvas, retaining its surface — no restart. `resizesCanvas` is
    /// passed by `TabController` when a drawer is open (so zooming even a lone pane really grows it,
    /// dock → full) — the canvas doesn't know drawer state itself.
    func zoomFocusedLeaf(resizesCanvas: Bool = false) {
        guard zoomedLeaf == nil else { return }
        zoomedLeaf = tree.focusedLeaf
        rebuildIfCollapsing()
        focusActivePane()
        popZoomTransition(resizesCanvas: resizesCanvas, growing: true)
    }

    /// Restore the split layout after `zoomFocusedLeaf()`.
    func unzoom(resizesCanvas: Bool = false) {
        guard zoomedLeaf != nil else { return }
        zoomedLeaf = nil
        rebuildIfCollapsing()
        focusActivePane()
        popZoomTransition(resizesCanvas: resizesCanvas, growing: false)
    }

    /// Rebuild the canvas tree for a zoom only when it actually collapses/expands the layout — i.e.
    /// a multi-pane split. A single-leaf canvas renders identically zoomed or not (the host fills
    /// either way), so rebuilding would only reparent the host and flicker it with nothing to show.
    private func rebuildIfCollapsing() {
        if tree.leafIDs.count > 1 { reconcileAndRender() }
    }

    /// Scale-pop the rebuilt canvas root on a zoom in/out (the full-screen pane, or the restored
    /// split). Skipped only for a true no-op — a lone pane with no drawer open, which is already
    /// full-screen so nothing changes; a multi-pane zoom or an open drawer both make it a real
    /// resize worth animating. Honors Reduce Motion via `Motion`.
    private func popZoomTransition(resizesCanvas: Bool, growing: Bool) {
        guard resizesCanvas || tree.leafIDs.count > 1, let root = canvasView.subviews.first else { return }
        canvasView.layoutSubtreeIfNeeded()  // give root its final frame before scaling about its center
        Motion.zoomPop(root, growing: growing)
    }

    /// Give panes the tab's unified focus halo (`on == true`), or yield it — used
    /// when a drawer takes focus so at most one panel is haloed across the tab.
    func setPanesFocused(_ on: Bool) {
        panesHoldFocus = on
        updateHalo()
    }

    // Focus routing (fleshed out in Task 10).
    func focus(_ id: PaneID) {
        guard tree.contains(id) else { return }
        tree.focusedLeaf = id
        updateHalo()
        onTitleChanged?()
        registry.surface(for: id)?.focus()
        onFocusChanged?()
    }

    private func focusFrontmost() { focus(tree.focusedLeaf) }

    /// Restore focus + halo to this tab's focused pane (used when its tab is
    /// re-mounted after a switch).
    func focusActivePane() { focus(tree.focusedLeaf) }

    /// Every leaf's on-screen frame converted into `target`'s coordinate space, with
    /// the same y-flip cross-panel nav needs: AppKit is y-up, but `nearestLeaf`'s
    /// scorer treats `.up` as decreasing y (top-left origin), so each frame is
    /// flipped (`h - maxY`) using `target`'s own height. `TabController` calls this
    /// with its `content` view so drawer panel frames (converted + flipped the same
    /// way) score uniformly alongside these.
    func leafFrames(in target: NSView) -> [PaneID: CGRect] {
        let h = target.bounds.height
        var frames: [PaneID: CGRect] = [:]
        for (id, host) in hostByLeaf {
            let f = host.convert(host.bounds, to: target)
            frames[id] = CGRect(x: f.minX, y: h - f.maxY, width: f.width, height: f.height)
        }
        return frames
    }

    /// The pane tree's currently focused leaf.
    var focusedLeafID: PaneID { tree.focusedLeaf }

    /// Public entry point to focus a specific leaf — used by `TabController`'s
    /// cross-panel spatial nav when it resolves to a pane.
    func focusLeaf(_ id: PaneID) { focus(id) }

    /// Split the focused pane along `axis`, unless it is too small to halve usefully.
    func split(_ axis: SplitAxis) {
        guard let host = hostByLeaf[tree.focusedLeaf] else { return }
        let size = host.bounds.size
        let extent = (axis == .vertical) ? size.width : size.height
        guard extent >= Self.minSplitExtent else { NSSound.beep(); return }

        let source = tree.focusedLeaf
        let newLeaf = mintPaneID()
        let newSplit = mintSplitID()
        // inherit the focused pane's live cwd (falls back to last OSC-reported)
        cwdByLeaf[newLeaf] = registry.surface(for: source)?.currentDirectory ?? cwdByLeaf[source]
        tree = tree.splitting(source, axis: axis, newLeaf: newLeaf, newSplit: newSplit)
        reconcileAndRender()
        // `focusActivePane()` goes through `focus(_:)` (halo + first-responder +
        // `onFocusChanged`), unlike a raw `.focus()` — so a split while a drawer holds
        // unified focus re-syncs `TabController.focusedPanel` back to `.pane` instead
        // of leaving the halo stuck on the drawer.
        focusActivePane()
        // Push the new pane in like a drawer: the source compresses (real resize) while the new pane
        // slides in at its final size. Lay out at the final ratio first so the split knows the child
        // sizes, then hand off. Reduce Motion keeps the instant appearance.
        if !Motion.isReduceMotionEnabled(), let split = splitViewByID[newSplit] {
            canvasView.layoutSubtreeIfNeeded()  // the compressing pane's one reflow, at its final ratio
            split.animateSplitIn(
                duration: Motion.pageSlideDuration, timing: Motion.landingTiming,
                suspendGrids: { [weak self] suspended in
                    self?.allSurfaces.forEach { $0.setSizeSyncSuspended(suspended) }
                })
        }
    }

    /// Resize the focused pane by moving its edge in `direction`: it grows into a neighbor
    /// that way, or shrinks (moving the opposite divider) when it's flush to that edge.
    /// `.right`/`.down` push positive, `.left`/`.up` negative. The nudge is clamped so both
    /// sides of the moved split stay ≥ `minSplitExtent` in pixels; beeps when there's no
    /// split of that axis or the split is already at that floor. Re-renders, keeps focus.
    func resize(_ direction: Direction) {
        let axis: SplitAxis = (direction == .left || direction == .right) ? .vertical : .horizontal
        let positive = (direction == .right || direction == .down)
        guard let split = tree.edgeSplitID(for: tree.focusedLeaf, axis: axis, positive: positive),
            let current = tree.ratio(of: split)
        else { NSSound.beep(); return }
        let minRatio = minRatioForSplit(split, axis: axis)
        let next = min(max(current + (positive ? Self.resizeStep : -Self.resizeStep), minRatio), 1 - minRatio)
        guard abs(next - current) > 1e-6 else { NSSound.beep(); return }  // already at the min-size wall
        tree = tree.settingRatio(split, to: next)
        if let container = splitViewByID[split] {
            // Key-repeatable hot path: swap the one ratio constraint in place. Nothing
            // detaches, so focus, halo, and first responder are untouched.
            container.setRatio(next)
        } else {
            // Defensive only: every split gets a container on rebuild, and the one state with
            // none built (zoomed) can't reach here — TabController blocks resize while zoomed.
            // A direct API call still lands correctly via a full rebuild.
            reconcileAndRender()
            focusActivePane()
        }
    }

    /// The smallest ratio that keeps BOTH sides of `split` at least `minSplitExtent` along
    /// `axis`, from the split's rendered extent (the max ratio is the mirror, `1 - this`).
    /// Each child loses `panelGap/2` to the gutter, so that half-gutter is folded into the
    /// floor — otherwise a pane could land ~4px under the minimum. Falls back to
    /// `minSplitRatio` before layout, and pins to 0.5 when the split can't honor the floor.
    private func minRatioForSplit(_ split: SplitID, axis: SplitAxis) -> Double {
        guard let view = splitViewByID[split] else { return Self.minSplitRatio }
        let extent = axis == .vertical ? view.bounds.width : view.bounds.height
        guard extent > 0 else { return Self.minSplitRatio }
        let floor = Double(Self.minSplitExtent + ChromeMetrics.panelGap / 2)
        return min(0.5, floor / Double(extent))
    }

    /// Close the focused pane. Returns false when it was the last pane (caller closes the window).
    @discardableResult
    func closeFocused() -> Bool {
        let dying = tree.focusedLeaf
        guard let next = tree.closing(dying) else { return false }
        let closing = captureDyingPane(dying)
        tree = next
        clearZoomIfLeafGone()
        reconcileAndRender()
        dissolveClosedPane(closing)
        // See `split(_:)`: `focusActivePane()` fires `onFocusChanged` so unified focus
        // re-syncs to `.pane` instead of getting stuck on a previously focused drawer.
        focusActivePane()
        return true
    }

    /// Snapshot a pane's host + on-screen frame *before* the reconcile drops it, so
    /// `dissolveClosedPane` can fade it out over the collapsed layout. Nil (no animation) when the
    /// canvas isn't in a window.
    private func captureDyingPane(_ id: PaneID) -> (host: PanelHostView, frame: CGRect)? {
        guard let host = hostByLeaf[id], canvasView.window != nil else { return nil }
        return (host, host.convert(host.bounds, to: canvasView))
    }

    /// Fade + scale the just-closed pane out over the already-collapsed layout (its surviving sibling
    /// has filled behind it) — the close-out counterpart to the split-in push. The reconcile has
    /// terminated the surface, so this is a static pane dissolving. Honors Reduce Motion.
    private func dissolveClosedPane(_ closing: (host: PanelHostView, frame: CGRect)?) {
        guard let (host, frame) = closing else { return }
        host.removeFromSuperview()  // detach from its now-orphaned split container
        guard !Motion.isReduceMotionEnabled() else { return }
        host.isHitTransparent = true  // clicks in the vacated region fall through to the survivor beneath
        host.translatesAutoresizingMaskIntoConstraints = true
        host.frame = frame  // before addSubview, so the autoresizing-mask constraints capture it
        canvasView.addSubview(host)  // back on top of the rebuilt tree
        dissolvingHosts.append(host)  // survive a concurrent reconcile's rebuild instead of snapping away
        Motion.springScaleFade(host, appearing: false) { [weak self] in
            host.removeFromSuperview()
            self?.dissolvingHosts.removeAll { $0 === host }
        }
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
        for token in tokenByLeaf.values { NavRegistry.shared.unregister(token: token) }
        tokenByLeaf.removeAll()
        canvasView.subviews.forEach { $0.removeFromSuperview() }
        hostByLeaf.removeAll()
    }
}

extension PaneCanvasController: TerminalSurfaceDelegate {
    /// A pane's viewport moved in its buffer. Relayed with the surface attached so scroll mode
    /// can ignore every pane but the one it is driving.
    func surface(_ s: TerminalSurface, scrollPositionDidChange position: TerminalScrollPosition) {
        onScrollPosition?(s, position)
    }
    func surface(_ s: TerminalSurface, cwdDidChange url: URL) {
        guard let id = leafID(of: s) else { return }
        cwdByLeaf[id] = url
        if id == tree.focusedLeaf { onTitleChanged?() }
    }
    func surface(_ s: TerminalSurface, titleDidChange title: String) {
        guard let id = leafID(of: s), id == tree.focusedLeaf else { return }
        onTitleChanged?()
    }
    func surfaceWantsFocus(_ s: TerminalSurface) {
        guard let id = leafID(of: s) else { return }
        focus(id)
    }
    func surface(_ s: TerminalSurface, didPostNotification n: TerminalNotification) {
        onNotification?(n)
    }
    func surface(_ s: TerminalSurface, commandDidFinish result: TerminalCommandResult) {
        onCommandFinished?(result)
    }
    /// A program repainted its pane's background (OSC 11). Carry it to that pane's own fill so the
    /// padding around the terminal matches instead of ringing it in the theme color (ZEN-23).
    /// Scoped to the one host: the canvas, the other panes and every chrome role are untouched.
    ///
    /// A pane needs no `backgroundOverride` pull to go with this. `reconcile` starts a leaf's
    /// surface and builds its host in the same synchronous turn, and a host is dropped only when
    /// its leaf is removed and the surface terminated with it, so no repaint can land in a window
    /// where the host does not exist. A tool float, whose card is rebuilt on every open over a
    /// surface that kept running, is the one place that pull is load-bearing.
    func surface(_ s: TerminalSurface, backgroundDidChange color: TerminalColor) {
        guard let id = leafID(of: s) else { return }
        hostByLeaf[id]?.backgroundOverride = color
    }
    /// The pointer is over a link in one of the panes (nil when it leaves) — mirror it into the
    /// shared preview so the user sees where a Cmd+click would go (ZEN-24).
    func surface(_ s: TerminalSurface, hoveredLinkDidChange url: String?) {
        guard let id = leafID(of: s), let host = hostByLeaf[id] else { return }
        LinkPreviewPresenter.shared.update(url, near: host)
    }
    func surfaceDidExit(_ s: TerminalSurface, code: Int32?) {
        guard let id = leafID(of: s) else { return }
        closePane(id)
    }

    func surfaceDidFailToStart(_ s: TerminalSurface) {
        guard let id = leafID(of: s) else { return }
        onSurfaceStartFailed?(
            { [weak self] in self?.retryStart(id) },
            { [weak self] in self?.closePane(id) })
    }

    /// Drop a leaf whose surface is gone (shell exited) or dead (start failed): collapse
    /// its slot in the tree — or close the window if it was the last pane — then reconcile.
    private func closePane(_ id: PaneID) {
        guard let next = tree.closing(id) else {
            onLastPaneClosed?()  // last pane → close window
            return
        }
        let closing = captureDyingPane(id)
        tree = next
        clearZoomIfLeafGone()
        reconcileAndRender()
        dissolveClosedPane(closing)
        registry.surface(for: tree.focusedLeaf)?.focus()
    }

    /// Replay the stored launch on a leaf whose surface failed to start. Re-runs on the same
    /// surface object; a repeat failure re-fires `surfaceDidFailToStart` for a fresh notice.
    private func retryStart(_ id: PaneID) {
        guard let surface = registry.surface(for: id), let launch = launchByLeaf[id] else { return }
        surface.start(launch)
    }

    private func leafID(of surface: TerminalSurface) -> PaneID? {
        registry.ids.first { registry.surface(for: $0) === surface }
    }
}
