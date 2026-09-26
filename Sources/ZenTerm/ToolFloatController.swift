import AppKit
import TabKit
import TerminalKit

/// Per window, not per app: a surface is one `NSView` and lives in one view hierarchy.
final class ToolFloatController: NSObject, TerminalSurfaceDelegate {
    private let presentOverlay: (SurfaceFloatOverlay) -> Void
    private let focusedCWD: () -> URL?
    private let yieldFocus: () -> Void
    private let restoreFocus: () -> Void
    /// Optional: `TabList.activeID` traps on an empty list, and `closeTab` empties it before teardown reads this.
    private let currentTabID: () -> TabID?
    private let makeSurface: () -> TerminalSurface
    /// Its completion must arrive on the main thread: the continuation mutates state and presents the overlay.
    var resolveRepoRoot: (URL?, @escaping (URL?) -> Void) -> Void
    private var toggleGeneration = 0

    private var pendingOpen: ToolFloat?

    private var activeFloat: (spec: ToolFloat, surface: TerminalSurface, overlay: SurfaceFloatOverlay, tab: TabID?)?

    private var liveFloats: [String: (surface: TerminalSurface, anchor: URL?, spec: ToolFloat, tab: TabID?)] = [:]

    /// Its constraints can hold a persistent float's shared `surface.view`, so a fast re-show snaps it away first.
    private var dismissingOverlay: SurfaceFloatOverlay?

    var onStateChanged: (() -> Void)?
    var onRequestToast: ((ToastContent) -> Void)?
    var onNotification: ((SurfaceID, TerminalNotification, ToolFloat, TabID?) -> Void)?

    var onProgress: ((SurfaceID, TerminalProgress?) -> Void)?

    var onTitle: ((SurfaceID, String) -> Void)?

    var onSurfaceRegistered: ((SurfaceID, TabID?) -> Void)?

    var onProgramLaunched: ((SurfaceID, String) -> Void)?

    var onSurfaceReleased: ((SurfaceID) -> Void)?

    /// A float is seen when it is shown, not when it takes first responder: showing is the only moment it is looked at.
    var onShown: ((SurfaceID) -> Void)?
    var onFocusChanged: (() -> Void)?

    // Keyed by the surface object: `surfaceForFloat` reuses a live surface, and a rebuilt registry key can disagree.
    private var idBySurface: [ObjectIdentifier: SurfaceID] = [:]

    var onSurfaceEvent: ((TerminalSurface, SurfaceEvent) -> Void)?

    init(
        presentOverlay: @escaping (SurfaceFloatOverlay) -> Void,
        focusedCWD: @escaping () -> URL?,
        yieldFocus: @escaping () -> Void,
        restoreFocus: @escaping () -> Void,
        currentTabID: @escaping () -> TabID? = { nil },
        makeSurface: @escaping () -> TerminalSurface = TerminalSurfaceFactory.make,
        resolveRepoRoot: @escaping (URL?, @escaping (URL?) -> Void) -> Void = GitRepoStatus.repoRoot
    ) {
        self.presentOverlay = presentOverlay
        self.focusedCWD = focusedCWD
        self.yieldFocus = yieldFocus
        self.restoreFocus = restoreFocus
        self.currentTabID = currentTabID
        self.makeSurface = makeSurface
        self.resolveRepoRoot = resolveRepoRoot
        super.init()
    }

    var isOpen: Bool { activeFloat != nil }
    var activeID: String? { activeFloat?.spec.id }

    var hasBusy: Bool { allSurfaces.contains(where: \.isBusy) }

    func hasBusyInScope(_ tab: TabID) -> Bool {
        liveFloats.values.contains { $0.tab == tab && $0.surface.isBusy }
    }

    func hiddenRunningTitles(scope tab: TabID?) -> [String] {
        liveFloats.values
            .filter { $0.tab == tab && $0.surface.isBusy && activeFloat?.surface !== $0.surface }
            .map(\.spec.title)
            .sorted()
    }

    /// A float id is a slug, so the `/` in `tab/id` can never collide with a user float's id.
    private func registryKey(_ id: String, in tab: TabID?) -> String {
        guard let tab else { return id }
        return "\(tab.raw)/\(id)"
    }

    private func registryKey(for spec: ToolFloat) -> String {
        registryKey(spec.id, in: scopedTab(for: spec))
    }

    private func scopedTab(for spec: ToolFloat) -> TabID? {
        spec.scope == .tab ? currentTabID() : nil
    }

    /// Registry membership rather than `isBusy`: membership pushes through `onStateChanged`, `isBusy` needs polling.
    func isLiveInBackground(_ id: String) -> Bool {
        guard activeID != id else { return false }
        if liveFloats[id] != nil { return true }
        return liveFloats[registryKey(id, in: currentTabID())] != nil
    }

    func isBusy(_ id: String) -> Bool {
        if let live = liveFloats[id] { return live.surface.isBusy }
        return liveFloats[registryKey(id, in: currentTabID())]?.surface.isBusy == true
    }

    func surfaceID(_ id: String) -> SurfaceID? {
        let live = liveFloats[id] ?? liveFloats[registryKey(id, in: currentTabID())]
        guard let surface = live?.surface ?? (activeID == id ? activeFloat?.surface : nil) else {
            return nil
        }
        return idBySurface[ObjectIdentifier(surface)]
    }

    func surface(_ id: SurfaceID) -> TerminalSurface? {
        allSurfaces.first { idBySurface[ObjectIdentifier($0)] == id }
    }

    func float(of id: SurfaceID) -> (spec: ToolFloat, tab: TabID?)? {
        if let active = activeFloat, idBySurface[ObjectIdentifier(active.surface)] == id {
            return (active.spec, active.tab)
        }
        return liveFloats.values.first { idBySurface[ObjectIdentifier($0.surface)] == id }.map { ($0.spec, $0.tab) }
    }

    var allSurfaces: [TerminalSurface] {
        var result = liveFloats.values.map(\.surface)
        if let active = activeFloat, !result.contains(where: { $0 === active.surface }) {
            result.append(active.surface)
        }
        return result
    }

    var shownSurface: TerminalSurface? { activeFloat?.surface }
    var shownOverlayForTesting: SurfaceFloatOverlay? { activeFloat?.overlay }

    func refocus() { focusShown() }

    private func focusShown() {
        guard let active = activeFloat else { return }
        active.surface.focus()
        onFocusChanged?()
    }

    func setHoldsKeyFocus(_ holds: Bool) {
        holdsKeyFocus = holds
        syncFocus()
    }

    private var holdsKeyFocus = true

    private func syncFocus() {
        guard let active = activeFloat else { return }
        active.surface.setFocused(holdsKeyFocus)
        active.overlay.isHaloVisible = holdsKeyFocus
    }

    func reapplyTheme() { activeFloat?.overlay.reapplyTheme() }

    private func floatCWD(_ spec: ToolFloat) -> URL? { spec.dir ?? focusedCWD() }

    func toggle(_ spec: ToolFloat) {
        if pendingOpen?.id == spec.id { cancelPendingOpen(); return }
        if activeFloat?.spec.id == spec.id { close(); return }
        cancelPendingOpen()
        if activeFloat != nil { close() }

        let cwd = floatCWD(spec)
        guard spec.requiresGitRepo || spec.persist == .directory else {
            show(spec, cwd: cwd, anchor: nil)
            return
        }
        toggleGeneration += 1
        let generation = toggleGeneration
        pendingOpen = spec
        resolveRepoRoot(cwd) { [weak self] repoRoot in
            guard let self, generation == self.toggleGeneration else { return }
            self.pendingOpen = nil
            if spec.requiresGitRepo, repoRoot == nil {
                self.onRequestToast?(self.gitGuardToast(for: spec))
                return
            }
            let anchor = spec.persist == .directory ? (repoRoot ?? cwd?.standardizedFileURL) : nil
            self.show(spec, cwd: cwd, anchor: anchor)
        }
    }

    func cancelPendingOpen() {
        guard pendingOpen != nil else { return }
        pendingOpen = nil
        toggleGeneration += 1
    }

    private func gitGuardToast(for spec: ToolFloat) -> ToastContent {
        let message: String
        if let dir = spec.dir {
            message =
                "This tool float is pinned to \(PathDisplay.abbreviatingHome(dir.path)), "
                + "which isn't a Git repository."
        } else {
            message = "This needs a Git repository. Run `git init` here, or open a folder that has one."
        }
        return ToastContent(variant: .info, title: spec.title, message: message)
    }

    func reveal(_ id: SurfaceID) {
        if let active = activeFloat, idBySurface[ObjectIdentifier(active.surface)] == id {
            return focusShown()
        }
        guard let live = liveFloats.values.first(where: { idBySurface[ObjectIdentifier($0.surface)] == id }) else {
            return
        }
        cancelPendingOpen()
        if activeFloat != nil { close() }
        present(live.spec, live.surface, tab: live.tab)
    }

    private func show(_ spec: ToolFloat, cwd: URL?, anchor: URL?) {
        present(spec, surfaceForFloat(spec, cwd: cwd, anchor: anchor), tab: scopedTab(for: spec))
    }

    private func present(_ spec: ToolFloat, _ surface: TerminalSurface, tab: TabID?) {
        if let dismissing = dismissingOverlay, surface.view.isDescendant(of: dismissing) {
            dismissing.removeFromSuperview()
            dismissingOverlay = nil
        }
        let overlay = SurfaceFloatOverlay(
            content: surface.view,
            widthFraction: spec.widthFraction,
            heightFraction: spec.heightFraction,
            contentInset: 10,
            cornerRadius: 14,
            onDismiss: { [weak self] in self?.close() })
        overlay.backgroundOverride = surface.backgroundOverride
        presentOverlay(overlay)
        activeFloat = (spec, surface, overlay, tab)
        yieldFocus()
        focusShown()
        overlay.animateIn()
        idBySurface[ObjectIdentifier(surface)].map { onShown?($0) }
        onStateChanged?()
    }

    private func surfaceForFloat(_ spec: ToolFloat, cwd: URL?, anchor: URL?) -> TerminalSurface {
        let key = registryKey(for: spec)
        if let live = liveFloats[key] {
            let anchorHolds = spec.persist != .directory || live.anchor?.path == anchor?.path
            let spawnHolds = live.spec.command == spec.command && live.spec.dir == spec.dir
            if spec.persist != .ephemeral, anchorHolds, spawnHolds { return live.surface }
            discard(key)
        }
        let surface = spawn(spec, cwd: cwd)
        if spec.persist != .ephemeral {
            liveFloats[key] = (surface, anchor, spec, scopedTab(for: spec))
        }
        return surface
    }

    /// Matches the stored spec's id, not the key: a `.tab` key carries a tab prefix the catalog does not.
    func prune(against catalog: [ToolFloat]) {
        let ids = Set(catalog.map(\.id))
        if let pending = pendingOpen, !ids.contains(pending.id) { cancelPendingOpen() }
        if let active = activeFloat, !ids.contains(active.spec.id) { close() }
        for key in Array(liveFloats.keys) where !ids.contains(liveFloats[key]?.spec.id ?? key) {
            discard(key)
        }
    }

    /// An empty command is Scratch, which takes a pane's shell launch; the parser rejects an empty user `command:`.
    private func spawn(_ spec: ToolFloat, cwd: URL?) -> TerminalSurface {
        let surface = makeSurface()
        surface.delegate = self
        let surfaceID = SurfaceIDs.mint()
        idBySurface[ObjectIdentifier(surface)] = surfaceID
        onSurfaceRegistered?(surfaceID, scopedTab(for: spec))
        if spec.command.isEmpty {
            surface.start(ShellLaunch.shell(cwd: cwd))
        } else {
            surface.start(
                TerminalSurfaceConfig(
                    command: ShellLaunch.userShell, args: ["-l", "-i", "-c", spec.command],
                    workingDirectory: cwd, fontSize: SessionFontSize.points,
                    theme: Theme.current.terminal,
                    behavior: GeneralConfig.current.terminalBehavior))
            onProgramLaunched?(surfaceID, spec.command)
        }
        return surface
    }

    /// Clears the entry before terminate so a synchronous `surfaceDidExit` cannot resurrect it.
    private func discard(_ key: String) {
        guard let live = liveFloats.removeValue(forKey: key) else { return }
        release(live.surface)
        onStateChanged?()
    }

    /// Terminates `surface` and drops its `SurfaceID`, so attention for a gone float cannot outlive it.
    private func release(_ surface: TerminalSurface) {
        if let id = idBySurface.removeValue(forKey: ObjectIdentifier(surface)) { onSurfaceReleased?(id) }
        surface.terminate()
    }

    /// By surface: a key rebuilt from a spec can disagree with the key the entry was filed under.
    @discardableResult
    private func removeEntry(forSurface s: TerminalSurface) -> Bool {
        guard let key = liveFloats.first(where: { $0.value.surface === s })?.key else { return false }
        liveFloats.removeValue(forKey: key)
        return true
    }

    /// Parks the overlay before `animateOut`: under Reduce Motion the completion runs synchronously and clears the slot.
    func close() {
        cancelPendingOpen()
        guard let active = activeFloat else { return }
        activeFloat = nil
        let overlay = active.overlay
        if active.spec.persist != .ephemeral {
            dismissingOverlay?.removeFromSuperview()
            dismissingOverlay = overlay
        }
        overlay.animateOut { [weak self] in
            overlay.removeFromSuperview()
            if self?.dismissingOverlay === overlay { self?.dismissingOverlay = nil }
        }
        if active.spec.persist == .ephemeral { release(active.surface) }
        restoreFocus()
        onStateChanged?()
    }

    func shutdownScope(_ tab: TabID) {
        if let active = activeFloat, active.tab == tab {
            cancelPendingOpen()
            activeFloat = nil
            active.overlay.removeFromSuperview()
            release(active.surface)
        }
        for key in Array(liveFloats.keys) where liveFloats[key]?.tab == tab {
            liveFloats.removeValue(forKey: key).map { release($0.surface) }
        }
        onStateChanged?()
    }

    func shutdown() {
        cancelPendingOpen()
        activeFloat?.overlay.removeFromSuperview()
        activeFloat.map { release($0.surface) }
        activeFloat = nil
        dismissingOverlay?.removeFromSuperview()
        dismissingOverlay = nil
        for id in Array(liveFloats.keys) { discard(id) }
    }

    @objc func copyFromSurface(_ sender: Any?) {
        guard let text = activeFloat?.surface.copySelection(), !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc func pasteToSurface(_ sender: Any?) {
        guard let surface = activeFloat?.surface,
            let text = NSPasteboard.general.string(forType: .string)
        else { return }
        surface.paste(text)
    }

    @objc func selectAllInSurface(_ sender: Any?) {
        activeFloat?.surface.selectAll()
    }

    var shownTarget: (surface: TerminalSurface, host: TerminalModeHost)? {
        guard let active = activeFloat else { return nil }
        return (active.surface, active.overlay)
    }

    private func relay(_ s: TerminalSurface, _ event: SurfaceEvent) {
        guard let active = activeFloat, s === active.surface else { return }
        onSurfaceEvent?(s, event)
    }
    func surface(_ s: TerminalSurface, scrollPositionDidChange position: TerminalScrollPosition) {
        relay(s, .scrollPosition(position))
    }
    func surfaceGridDidReflow(_ s: TerminalSurface) {
        relay(s, .gridReflow)
    }
    func surfaceWantsFocus(_ s: TerminalSurface) {
        if s === activeFloat?.surface { focusShown() }
    }
    func surface(_ s: TerminalSurface, searchTotalDidChange total: Int?) {
        relay(s, .search(.total(total)))
    }
    func surface(_ s: TerminalSurface, searchSelectionDidChange index: Int?) {
        relay(s, .search(.selected(index)))
    }
    func surfaceDidEndSearch(_ s: TerminalSurface) {
        relay(s, .search(.ended))
    }
    func surface(_ s: TerminalSurface, wantsSearchWithNeedle needle: String) {
        relay(s, .search(.wanted(needle: needle)))
    }

    func surface(_ s: TerminalSurface, didPostNotification n: TerminalNotification) {
        guard let entry = entry(for: s), let id = idBySurface[ObjectIdentifier(s)] else { return }
        onNotification?(id, n, entry.spec, entry.tab)
    }

    func surface(_ s: TerminalSurface, progressDidChange p: TerminalProgress?) {
        guard let id = idBySurface[ObjectIdentifier(s)] else { return }
        onProgress?(id, p)
    }

    func surface(_ s: TerminalSurface, titleDidChange title: String) {
        guard let id = idBySurface[ObjectIdentifier(s)] else { return }
        onTitle?(id, title)
    }

    func surface(_ s: TerminalSurface, backgroundDidChange color: TerminalColor) {
        guard let active = activeFloat, s === active.surface else { return }
        active.overlay.backgroundOverride = color
    }

    func surface(_ s: TerminalSurface, hoveredLinkDidChange url: String?) {
        guard let active = activeFloat, s === active.surface else { return }
        LinkPreviewPresenter.shared.update(url, near: active.overlay)
    }

    private func entry(for s: TerminalSurface) -> (spec: ToolFloat, tab: TabID?)? {
        if let active = activeFloat, s === active.surface { return (active.spec, active.tab) }
        guard let live = liveFloats.values.first(where: { $0.surface === s }) else { return nil }
        return (live.spec, live.tab)
    }

    func surfaceDidExit(_ s: TerminalSurface, code: Int32?) {
        if let active = activeFloat, s === active.surface {
            activeFloat = nil
            removeEntry(forSurface: s)
            active.overlay.animateOut { active.overlay.removeFromSuperview() }
            release(active.surface)
            restoreFocus()
            onStateChanged?()
            return
        }
        if removeEntry(forSurface: s) {
            release(s)
            onStateChanged?()
        }
    }

    func surfaceDidFailToStart(_ s: TerminalSurface) {
        let descriptor: String
        if activeFloat?.surface === s {
            descriptor = "This tool float"
        } else if liveFloats.values.contains(where: { $0.surface === s }) {
            descriptor = "A background tool float"
        } else {
            return
        }
        onRequestToast?(
            ToastContent(
                variant: .warning, title: "Terminal Didn't Start",
                message: "\(descriptor) failed to launch. Open it again to retry."))
        surfaceDidExit(s, code: nil)
    }
}
