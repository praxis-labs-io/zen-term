import AppKit
import AppLog
import PaneKit
import TerminalKit

final class PaneCanvasController: NSObject {
    let canvasView = NSView()

    private var tree: PaneTree
    private let registry: PaneSurfaceRegistry
    private var cwdByLeaf: [PaneID: URL] = [:]
    private var hostByLeaf: [PaneID: PanelHostView] = [:]
    private var launchByLeaf: [PaneID: TerminalSurfaceConfig] = [:]
    private var tokenByLeaf: [PaneID: Int] = [:]
    /// Consumed on first start; a split never inherits it.
    private var startupCommandByLeaf: [PaneID: String] = [:]
    private let workspaceEnv: [String: String]
    private var nextID = 1

    private var zoomedLeaf: PaneID?
    var isZoomed: Bool { zoomedLeaf != nil }

    private var splitViewByID: [SplitID: SplitContainerView] = [:]

    /// Spared by `rebuildViews`, so a reconcile doesn't snap a fade away.
    private var dissolvingHosts: [NSView] = []

    private var panesHoldFocus = true

    private static let minSplitExtent: CGFloat = 240
    private static let resizeStep: Double = 0.04
    private static let minSplitRatio: Double = 0.12

    /// Fires only when the last shell exits on its own; a ⌘W goes through `closeFocused()`.
    var onLastPaneClosed: (() -> Void)?

    var onPanesRemoved: (([PaneID]) -> Void)?

    var onTitleChanged: (() -> Void)?

    var onFocusChanged: (() -> Void)?

    var onSurfaceEvent: ((TerminalSurface, SurfaceEvent) -> Void)?

    var onSocketFocus: ((Direction) -> Void)?

    var onNotification: ((TerminalNotification) -> Void)?

    var onCommandFinished: ((TerminalCommandResult) -> Void)?

    var onZoomEnded: (() -> Void)?

    var onSurfaceStartFailed: ((_ retry: @escaping () -> Void, _ close: @escaping () -> Void) -> Void)?

    private func clearZoomIfLeafGone() {
        if let z = zoomedLeaf, !tree.leafIDs.contains(z) {
            zoomedLeaf = nil
            onZoomEnded?()
        }
    }

    /// Prefers the live process cwd, so inheritance works without OSC 7.
    var focusedCWD: URL? {
        registry.surface(for: tree.focusedLeaf)?.currentDirectory ?? cwdByLeaf[tree.focusedLeaf]
    }

    var paneCount: Int { tree.leafIDs.count }

    var allSurfaces: [TerminalSurface] { registry.allSurfaces }

    /// `allSurfaces` comes off a dictionary and has no order.
    var orderedLeafIDs: [PaneID] { tree.leafIDs }

    func surface(for id: PaneID) -> TerminalSurface? { registry.surface(for: id) }

    var focusedScrollTarget: (surface: TerminalSurface, panel: PanelHostView)? {
        guard let surface = registry.surface(for: tree.focusedLeaf),
            let panel = hostByLeaf[tree.focusedLeaf]
        else { return nil }
        return (surface, panel)
    }

    var focusedPaneIsBusy: Bool {
        registry.surface(for: tree.focusedLeaf)?.isBusy ?? false
    }

    var focusedPaneToken: Int? { tokenByLeaf[tree.focusedLeaf] }

    var focusedPaneIsVim: Bool {
        guard let token = focusedPaneToken else { return false }
        return NavRegistry.shared.isVim(token: token)
    }

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
        canvasView.wantsLayer = true
        canvasView.layer?.backgroundColor = NSColor.clear.cgColor
    }

    private func mintPaneID() -> PaneID { defer { nextID += 1 }; return PaneID(nextID) }
    private func mintSplitID() -> SplitID { defer { nextID += 1 }; return SplitID(nextID) }

    /// Only the focused pane may hand off, so a stale or background `focus` is dropped.
    private func registerNavToken(for id: PaneID) -> Int {
        let token = NavRegistry.shared.mintToken()
        tokenByLeaf[id] = token
        NavRegistry.shared.register(token: token) { [weak self] dir in
            guard let self, self.focusedPaneToken == token else { return }
            self.onSocketFocus?(dir)
        }
        return token
    }

    private func navEnv(token: Int) -> [String: String] {
        NavSocketServer.env(base: workspaceEnv, token: token)
    }

    func start() {
        reconcileAndRender()
        focusFrontmost()
    }

    private func reconcileAndRender() {
        let diff = paneDiff(from: Array(registry.ids), to: tree.leafIDs)
        let created = registry.apply(diff)
        for (id, surface) in created {
            surface.delegate = self
            let token = registerNavToken(for: id)
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
        for subview in canvasView.subviews where !dissolvingHosts.contains(where: { $0 === subview }) {
            subview.removeFromSuperview()
        }
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
        canvasView.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: canvasView.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: canvasView.trailingAnchor),
            root.topAnchor.constraint(equalTo: canvasView.topAnchor),
            root.bottomAnchor.constraint(equalTo: canvasView.bottomAnchor),
        ])
        dissolvingHosts.forEach { canvasView.addSubview($0) }
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

    var hostsForTesting: [PaneID: PanelHostView] { hostByLeaf }

    /// Sets cursor focus explicitly: the responder chain alone leaves stale blinking cursors after rapid splits.
    private func updateHalo() {
        for (id, host) in hostByLeaf {
            let focused = panesHoldFocus && (id == tree.focusedLeaf)
            host.isFocused = focused
            host.isZoomed = (id == zoomedLeaf)
            registry.surface(for: id)?.setFocused(focused && focusedSurfaceRendersFocused)
        }
    }

    /// Stored, because `updateHalo` rewrites the same state on every restructure.
    private var focusedSurfaceRendersFocused = true

    func setFocusedSurfaceRendersFocused(_ focused: Bool) {
        focusedSurfaceRendersFocused = focused
        updateHalo()
    }

    func reapplyChromeColors() {
        for host in hostByLeaf.values { host.reapplyTheme() }
    }

    func reapplyChromeLayout() {
        for split in splitViewByID.values { split.setGutter(ChromeMetrics.panelGap) }
        for host in hostByLeaf.values { host.reapplyChromeLayout() }
    }

    func zoomFocusedLeaf(resizesCanvas: Bool = false) {
        guard zoomedLeaf == nil else { return }
        zoomedLeaf = tree.focusedLeaf
        rebuildIfCollapsing()
        focus(tree.focusedLeaf, announces: false)
        popZoomTransition(resizesCanvas: resizesCanvas, growing: true)
    }

    func unzoom(resizesCanvas: Bool = false) {
        guard zoomedLeaf != nil else { return }
        zoomedLeaf = nil
        rebuildIfCollapsing()
        focus(tree.focusedLeaf, announces: false)
        popZoomTransition(resizesCanvas: resizesCanvas, growing: false)
    }

    private func rebuildIfCollapsing() {
        if tree.leafIDs.count > 1 { reconcileAndRender() }
    }

    private func popZoomTransition(resizesCanvas: Bool, growing: Bool) {
        guard resizesCanvas || tree.leafIDs.count > 1, let root = canvasView.subviews.first else { return }
        canvasView.layoutSubtreeIfNeeded()
        Motion.zoomPop(root, growing: growing)
    }

    func setPanesFocused(_ on: Bool) {
        panesHoldFocus = on
        updateHalo()
    }

    func focus(_ id: PaneID) { focus(id, announces: true) }

    private func focus(_ id: PaneID, announces: Bool) {
        guard tree.contains(id) else { return }
        tree.focusedLeaf = id
        updateHalo()
        onTitleChanged?()
        registry.surface(for: id)?.focus()
        if announces { onFocusChanged?() }
    }

    private func focusFrontmost() { focus(tree.focusedLeaf) }

    func focusActivePane() { focus(tree.focusedLeaf) }

    func leafFrames(in target: NSView) -> [PaneID: CGRect] {
        let h = target.bounds.height
        var frames: [PaneID: CGRect] = [:]
        for (id, host) in hostByLeaf {
            let f = host.convert(host.bounds, to: target)
            frames[id] = CGRect(x: f.minX, y: h - f.maxY, width: f.width, height: f.height)
        }
        return frames
    }

    var focusedLeafID: PaneID { tree.focusedLeaf }

    func focusLeaf(_ id: PaneID) { focus(id) }

    func split(_ axis: SplitAxis) {
        guard let host = hostByLeaf[tree.focusedLeaf] else { return }
        let size = host.bounds.size
        let extent = (axis == .vertical) ? size.width : size.height
        guard extent >= Self.minSplitExtent else { NSSound.beep(); return }

        let source = tree.focusedLeaf
        let newLeaf = mintPaneID()
        let newSplit = mintSplitID()
        cwdByLeaf[newLeaf] = registry.surface(for: source)?.currentDirectory ?? cwdByLeaf[source]
        tree = tree.splitting(source, axis: axis, newLeaf: newLeaf, newSplit: newSplit)
        reconcileAndRender()
        focusActivePane()
        if !Motion.isReduceMotionEnabled(), let split = splitViewByID[newSplit] {
            canvasView.layoutSubtreeIfNeeded()
            split.animateSplitIn(
                duration: Motion.pageSlideDuration, timing: Motion.landingTiming,
                suspendGrids: { [weak self] suspended in
                    self?.allSurfaces.forEach { $0.setSizeSyncSuspended(suspended) }
                })
        }
    }

    func resize(_ direction: Direction) {
        let axis: SplitAxis = (direction == .left || direction == .right) ? .vertical : .horizontal
        let positive = (direction == .right || direction == .down)
        guard let split = tree.edgeSplitID(for: tree.focusedLeaf, axis: axis, positive: positive),
            let current = tree.ratio(of: split)
        else { NSSound.beep(); return }
        let minRatio = minRatioForSplit(split, axis: axis)
        let next = min(max(current + (positive ? Self.resizeStep : -Self.resizeStep), minRatio), 1 - minRatio)
        guard abs(next - current) > 1e-6 else { NSSound.beep(); return }
        tree = tree.settingRatio(split, to: next)
        if let container = splitViewByID[split] {
            container.setRatio(next)
        } else {
            reconcileAndRender()
            focusActivePane()
        }
    }

    private func minRatioForSplit(_ split: SplitID, axis: SplitAxis) -> Double {
        guard let view = splitViewByID[split] else { return Self.minSplitRatio }
        let extent = axis == .vertical ? view.bounds.width : view.bounds.height
        guard extent > 0 else { return Self.minSplitRatio }
        let floor = Double(Self.minSplitExtent + ChromeMetrics.panelGap / 2)
        return min(0.5, floor / Double(extent))
    }

    @discardableResult
    func closeFocused() -> Bool {
        let dying = tree.focusedLeaf
        guard let next = tree.closing(dying) else { return false }
        let closing = captureDyingPane(dying)
        tree = next
        clearZoomIfLeafGone()
        reconcileAndRender()
        dissolveClosedPane(closing)
        focusActivePane()
        return true
    }

    private func captureDyingPane(_ id: PaneID) -> (host: PanelHostView, frame: CGRect)? {
        guard let host = hostByLeaf[id], canvasView.window != nil else { return nil }
        return (host, host.convert(host.bounds, to: canvasView))
    }

    private func dissolveClosedPane(_ closing: (host: PanelHostView, frame: CGRect)?) {
        guard let (host, frame) = closing else { return }
        host.removeFromSuperview()
        guard !Motion.isReduceMotionEnabled() else { return }
        host.isHitTransparent = true
        host.translatesAutoresizingMaskIntoConstraints = true
        host.frame = frame
        canvasView.addSubview(host)
        dissolvingHosts.append(host)
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

    func shutdown() {
        registry.terminateAll()
        for token in tokenByLeaf.values { NavRegistry.shared.unregister(token: token) }
        tokenByLeaf.removeAll()
        canvasView.subviews.forEach { $0.removeFromSuperview() }
        hostByLeaf.removeAll()
    }
}

extension PaneCanvasController: TerminalSurfaceDelegate {
    func surface(_ s: TerminalSurface, scrollPositionDidChange position: TerminalScrollPosition) {
        onSurfaceEvent?(s, .scrollPosition(position))
    }
    func surfaceGridDidReflow(_ s: TerminalSurface) {
        onSurfaceEvent?(s, .gridReflow)
    }
    func surface(_ s: TerminalSurface, searchTotalDidChange total: Int?) {
        onSurfaceEvent?(s, .search(.total(total)))
    }
    func surface(_ s: TerminalSurface, searchSelectionDidChange index: Int?) {
        onSurfaceEvent?(s, .search(.selected(index)))
    }
    func surfaceDidEndSearch(_ s: TerminalSurface) {
        onSurfaceEvent?(s, .search(.ended))
    }
    func surface(_ s: TerminalSurface, wantsSearchWithNeedle needle: String) {
        onSurfaceEvent?(s, .search(.wanted(needle: needle)))
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
    func surface(_ s: TerminalSurface, backgroundDidChange color: TerminalColor) {
        guard let id = leafID(of: s) else { return }
        hostByLeaf[id]?.backgroundOverride = color
    }
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

    private func closePane(_ id: PaneID) {
        guard let next = tree.closing(id) else {
            onLastPaneClosed?()
            return
        }
        let closing = captureDyingPane(id)
        tree = next
        clearZoomIfLeafGone()
        reconcileAndRender()
        dissolveClosedPane(closing)
        registry.surface(for: tree.focusedLeaf)?.focus()
    }

    private func retryStart(_ id: PaneID) {
        guard let surface = registry.surface(for: id), let launch = launchByLeaf[id] else { return }
        surface.start(launch)
    }

    private func leafID(of surface: TerminalSurface) -> PaneID? {
        registry.ids.first { registry.surface(for: $0) === surface }
    }
}
