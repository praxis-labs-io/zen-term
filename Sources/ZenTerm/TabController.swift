import AppKit
import PaneKit
import TerminalKit

/// Which edge a drawer panel docks to.
enum DrawerEdge { case bottom, right }

/// Which panel is filling the tab (zoomed), for the footer dock's zoom tint.
enum ZoomedPanel: Equatable { case pane, bottomDrawer, rightDrawer }

/// A tab's overlay open-state (drawers + lazygit + zoom), produced by `TabController`
/// and mirrored by the footer toggle dock's active tints.
struct OverlayState: Equatable {
    var isBottomOpen = false
    var isRightOpen = false
    var isLazygitOpen = false
    var activeToolFloatID: String?
    var zoomed: ZoomedPanel?
}

/// One tab: owns the pane tree (`PaneCanvasController`) and the per-tab overlay
/// surfaces (drawers, lazygit) and zoom. `view` is the tab's container that
/// `WindowController` mounts. `content` is the tab's tile region (inset from `view`
/// to clear the traffic lights and match the pane gutter); the pane canvas and any
/// open drawers tile within it as sibling panels — right drawer as a full-height
/// column, bottom drawer under the canvas in the remaining left column — separated
/// by the same gutter panes use (`ChromeMetrics.panelGap`), never overlapping.
final class TabController: NSObject {
    let view = NSView()
    private let content = NSView()
    private let paneCanvas: PaneCanvasController
    private let canvas: NSView  // paneCanvas.canvasView, cached

    // Drawer sizes are seeded proportionally from the tab's working area the first time
    // `content` has a real size — a bit under a third each, which lands near the ~300/480
    // that felt right on a MacBook Air, while the caps keep drawers from ballooning on large
    // displays. The stored vars start at those values as a fallback for the (unreachable in
    // practice) case of a drawer opening before `content` is laid out.
    private static let bottomDrawerFraction: CGFloat = 0.28
    private static let rightDrawerFraction: CGFloat = 0.30
    private static let bottomDrawerMax: CGFloat = 360
    private static let rightDrawerMax: CGFloat = 560
    private var bottomDrawerHeight: CGFloat = 300
    private var rightDrawerWidth: CGFloat = 480
    private var didSeedDrawerSizes = false
    /// One ⌥-arrow nudge for a focused drawer, and the floor it can shrink to; a drawer
    /// never grows past 70% of the working area (the canvas keeps the rest).
    private static let drawerResizeStep: CGFloat = 40
    private static let minDrawerExtent: CGFloat = 160
    private static let maxDrawerFraction: CGFloat = 0.7

    // Per-tab auxiliary surfaces (created lazily; kept alive when hidden — the shell
    // persists across toggles and is only terminated in `shutdown()`).
    private var bottomDrawerSurface: TerminalSurface?
    private var bottomDrawerPanel: PanelHostView?
    private var isBottomOpen = false { didSet { onOverlayStateChanged?() } }

    private var rightDrawerSurface: TerminalSurface?
    private var rightDrawerPanel: PanelHostView?
    private var isRightOpen = false { didSet { onOverlayStateChanged?() } }

    // The lazygit float. Like the drawers, its surface is PERSISTENT: created once
    // (pre-warmed in the background for repo/workspace tabs, else lazily on the first
    // ⌘G) and kept alive for the tab's lifetime — dismiss only hides it. The overlay,
    // not the surface, tracks visibility, so `isLazygitOpen` still means "shown/modal".
    private var lazygitSurface: TerminalSurface?
    private var lazygitOverlay: LazygitOverlay?
    /// An overlay still springing out after `hideLazygit`. It keeps Auto Layout constraints
    /// to the shared `lazygitSurface.view` until its exit animation finishes, so a fast
    /// re-show must snap it away first (see `showLazygit`) before reparenting that view.
    private var lazygitDismissingOverlay: LazygitOverlay?
    /// The git repo root (or plain cwd) the live `lazygitSurface` was launched against.
    /// `⌘G` reloads the surface when the focused pane has since moved to a different
    /// repo/dir, so lazygit tracks the pane instead of showing a stale directory.
    private var lazygitLaunchAnchor: URL?
    var isLazygitOpen: Bool { lazygitOverlay != nil }

    /// The single live ephemeral tool float (diffnav, …). Tool floats are modal and
    /// mutually exclusive, so one slot suffices. Terminated on close (not persisted).
    private var activeToolFloat: (spec: ToolFloat, surface: TerminalSurface, overlay: SurfaceFloatOverlay)?
    var isToolFloatOpen: Bool { activeToolFloat != nil }
    var activeToolFloatID: String? { activeToolFloat?.spec.id }

    /// Which panel currently holds the tab's single unified focus/halo.
    private enum PanelRef: Equatable {
        case pane, bottomDrawer, rightDrawer
        var asZoomed: ZoomedPanel {
            switch self {
            case .pane: return .pane
            case .bottomDrawer: return .bottomDrawer
            case .rightDrawer: return .rightDrawer
            }
        }
    }
    private var focusedPanel: PanelRef = .pane

    /// The zoomed panel (fills the tab, others hidden), or nil when not zoomed.
    /// Toggling it re-renders the footer dock so the zoom tint tracks it.
    private var zoomedPanel: PanelRef? { didSet { onOverlayStateChanged?() } }
    var isZoomed: Bool { zoomedPanel != nil }

    /// The focused drawer's surface, or nil when the pane canvas is focused (copy/
    /// paste then routes to `paneCanvas` as before).
    private var focusedDrawerSurface: TerminalSurface? {
        switch focusedPanel {
        case .pane: return nil
        case .bottomDrawer: return bottomDrawerSurface
        case .rightDrawer: return rightDrawerSurface
        }
    }

    /// The currently active tile constraints (canvas + open drawer panels), rebuilt
    /// from scratch on every `relayoutPanels()` call so repeated toggles never
    /// accumulate constraints.
    private var tileConstraints: [NSLayoutConstraint] = []

    var onTitleChanged: (() -> Void)? {
        get { paneCanvas.onTitleChanged }
        set { paneCanvas.onTitleChanged = newValue }
    }
    var onLastPaneClosed: (() -> Void)? {
        get { paneCanvas.onLastPaneClosed }
        set { paneCanvas.onLastPaneClosed = newValue }
    }

    /// A pinned tab name (set when opened via the `⌘P` repo picker): overrides the
    /// live cwd-derived title so the tab keeps the project's name no matter where the
    /// focused pane's shell `cd`s. Nil for tabs opened any other way.
    var pinnedTitle: String?
    var title: String { pinnedTitle ?? paneCanvas.title }
    var focusedCWD: URL? { paneCanvas.focusedCWD }

    /// True when the tab has a single pane, so ⌘W on it would close the whole tab.
    var isSinglePane: Bool { paneCanvas.paneCount == 1 }

    /// Whether the focused main-canvas pane has a running process.
    var focusedPaneIsBusy: Bool { paneCanvas.focusedPaneIsBusy }

    /// Whether either drawer has a running process — closing the tab would stop it. (An idle
    /// drawer isn't worth a confirm; only a busy one is.)
    var hasBusyDrawer: Bool {
        bottomDrawerSurface?.isBusy == true || rightDrawerSurface?.isBusy == true
    }

    /// The tab's overlay open-state (drawers + lazygit), for the footer dock's active
    /// tints; fired via `onOverlayStateChanged` whenever one of them toggles.
    var overlayState: OverlayState {
        OverlayState(
            isBottomOpen: isBottomOpen, isRightOpen: isRightOpen,
            isLazygitOpen: isLazygitOpen, activeToolFloatID: activeToolFloatID,
            zoomed: zoomedPanel.map(\.asZoomed))
    }
    var onOverlayStateChanged: (() -> Void)?

    /// Request a transient top-right toast (e.g. `⌘G` blocked outside a git repo).
    var onRequestToast: ((ToastContent) -> Void)?

    /// The tab's focused surface changed (a pane or drawer click, or spatial nav). Lets a
    /// host void a pending close confirm whose target/modality just moved out from under it.
    var onFocusChanged: (() -> Void)?

    /// A startup command for the right drawer (the `⌘P` workspace preset sets `claude`).
    /// When set, opening the right drawer launches the program-then-shell recipe instead
    /// of a plain shell. Nil → plain shell.
    var rightDrawerCommand: String?

    init(initialCWD: URL?, initialCommand: String? = nil) {
        paneCanvas = PaneCanvasController(initialCWD: initialCWD, initialCommand: initialCommand)
        canvas = paneCanvas.canvasView
        canvas.translatesAutoresizingMaskIntoConstraints = false
        super.init()

        content.translatesAutoresizingMaskIntoConstraints = false
        // Layer-back the tile container so the floats added into it later (⌘P picker, lazygit)
        // composite their drop shadows — a layer-backed view dropped into a non-layer-backed
        // parent after layout doesn't render its shadow.
        content.wantsLayer = true
        view.addSubview(content)
        // Content-rect inset: an even `windowGutter` on all four sides (the traffic
        // lights are hidden, so the top no longer needs extra clearance).
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: ChromeMetrics.windowGutter),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -ChromeMetrics.windowGutter),
            content.topAnchor.constraint(equalTo: view.topAnchor, constant: ChromeMetrics.windowGutter),
            content.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -ChromeMetrics.windowGutter),
        ])
        content.addSubview(canvas)
        relayoutPanels()

        paneCanvas.onFocusChanged = { [weak self] in self?.paneGainedFocus() }
        paneCanvas.onZoomExitRequested = { [weak self] in self?.toggleZoom() }
        paneCanvas.onZoomEnded = { [weak self] in self?.paneZoomEndedInternally() }
    }

    /// The pane canvas ended zoom on its own (the zoomed leaf's shell exited) — clear
    /// our matching zoom state and re-tile so hidden drawers reappear.
    private func paneZoomEndedInternally() {
        if zoomedPanel == .pane {
            zoomedPanel = nil
            relayoutPanels()
        }
    }

    func start() { paneCanvas.start() }
    func split(_ axis: SplitAxis) { exitZoomIfNeeded(); paneCanvas.split(axis) }
    @discardableResult func closeFocused() -> Bool {
        exitZoomIfNeeded()  // exit zoom before closing so zoom state can't desync
        return paneCanvas.closeFocused()
    }
    func focusActivePane() { paneCanvas.focusActivePane() }

    /// The `⌘P` workspace layout: reveal the bottom drawer (a plain shell) and the right
    /// drawer (running `rightDrawerCommand`, i.e. claude), then land focus on the primary
    /// pane (nvim). Called once right after `start()` for a repo-opened tab.
    func openWorkspaceLayout() {
        if !isBottomOpen { toggleBottomDrawer() }
        if !isRightOpen { toggleRightDrawer() }
        focusActivePane()
        prewarmLazygit()  // repo tab has a stable cwd → pre-warm so the first ⌘G is instant
    }

    /// Present a modal overlay filling the tab's tile region — same scoping as the
    /// lazygit float (pinned to `content`, above the canvas and any drawers). Used by
    /// `WindowController` to host the window-level `⌘P` repo picker over the active tab.
    func presentTileOverlay(_ overlay: NSView) {
        overlay.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: content.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
    }

    /// Restore keyboard focus when this tab is (re)mounted: the modal lazygit float if
    /// open — it must keep first-responder, it's modal over the whole tab — otherwise
    /// whichever panel held the tab's unified focus (pane or a drawer). Without the
    /// float check, remounting steals focus to the pane hidden behind the still-visible
    /// float; without honoring `focusedPanel`, remounting a tab that was focused on a
    /// drawer wrongly drops focus onto the central pane.
    func restoreKeyFocus() {
        if isLazygitOpen { lazygitSurface?.focus(); return }
        if let active = activeToolFloat { active.surface.focus(); return }
        restoreUnifiedFocus()
    }

    func shutdown() {
        paneCanvas.shutdown()
        bottomDrawerSurface?.terminate()
        bottomDrawerSurface = nil
        rightDrawerSurface?.terminate()
        rightDrawerSurface = nil
        lazygitOverlay?.removeFromSuperview()
        lazygitOverlay = nil
        lazygitDismissingOverlay?.removeFromSuperview()
        lazygitDismissingOverlay = nil
        // `discardLazygitSurface` clears the ref before terminate, so a synchronous exit
        // re-entry can't re-warm a fresh surface that this teardown would then orphan.
        discardLazygitSurface()
        activeToolFloat?.overlay.removeFromSuperview()
        activeToolFloat?.surface.terminate()
        activeToolFloat = nil
    }

    /// Copy from whichever panel holds unified focus: the pane canvas's own copy
    /// path, or — for a focused drawer — its surface's selection straight to the
    /// pasteboard (mirrors `PaneCanvasController.copyFromSurface`).
    @objc func copyFromSurface(_ sender: Any?) {
        // While the modal float is open, copy targets it, not the panel underneath.
        // The surface persists while hidden, so gate on visibility (`isLazygitOpen`).
        guard
            let surface = (isLazygitOpen ? lazygitSurface : nil)
                ?? (isToolFloatOpen ? activeToolFloat?.surface : nil)
                ?? focusedDrawerSurface
        else {
            paneCanvas.copyFromSurface(sender)
            return
        }
        guard let text = surface.copySelection(), !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Paste into whichever panel holds unified focus (mirrors
    /// `PaneCanvasController.pasteToSurface` for the drawer case).
    @objc func pasteToSurface(_ sender: Any?) {
        // While the modal float is open, paste targets it, not the panel underneath.
        // The surface persists while hidden, so gate on visibility (`isLazygitOpen`).
        guard
            let surface = (isLazygitOpen ? lazygitSurface : nil)
                ?? (isToolFloatOpen ? activeToolFloat?.surface : nil)
                ?? focusedDrawerSurface
        else {
            paneCanvas.pasteToSurface(sender)
            return
        }
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        surface.paste(text)
    }

    // MARK: bottom drawer (⌘B)

    /// Toggle the bottom drawer. First open creates a persistent login-shell surface
    /// in the tab's cwd; toggling hidden keeps it running; it dies only in `shutdown()`.
    func toggleBottomDrawer() {
        exitZoomIfNeeded()  // any layout change exits zoom first (keeps state in sync)
        isBottomOpen.toggle()
        if isBottomOpen {
            _ = ensureBottomDrawerPanel()
            relayoutPanels()  // attaches + tiles it (visibility follows open state)
            focusDrawer(.bottom)
        } else {
            relayoutPanels()  // detaches it (surface stays alive)
            // Only restore focus if the drawer being hidden held unified focus — to the
            // other drawer if it's still open, else the pane.
            if focusedPanel == .bottomDrawer { restoreFocusAfterClosingDrawer(otherOpen: isRightOpen, other: .right) }
        }
    }

    private func ensureBottomDrawerPanel() -> PanelHostView {
        if let existing = bottomDrawerPanel { return existing }
        let surface = TerminalSurfaceFactory.make()
        surface.delegate = self
        surface.start(ShellLaunch.shell(cwd: focusedCWD))
        bottomDrawerSurface = surface
        let panel = makeDrawerPanel(edge: .bottom, surface: surface)
        bottomDrawerPanel = panel  // relayoutPanels() attaches it to `content`
        return panel
    }

    // MARK: right drawer (⌘|)

    /// Toggle the right drawer. First open creates a persistent login-shell surface
    /// in the tab's cwd; toggling hidden keeps it running; it dies only in `shutdown()`.
    func toggleRightDrawer() {
        exitZoomIfNeeded()
        isRightOpen.toggle()
        if isRightOpen {
            _ = ensureRightDrawerPanel()
            relayoutPanels()
            focusDrawer(.right)
        } else {
            relayoutPanels()
            // See `toggleBottomDrawer`: restore focus only if this drawer held it.
            if focusedPanel == .rightDrawer { restoreFocusAfterClosingDrawer(otherOpen: isBottomOpen, other: .bottom) }
        }
    }

    private func ensureRightDrawerPanel() -> PanelHostView {
        if let existing = rightDrawerPanel { return existing }
        let surface = TerminalSurfaceFactory.make()
        surface.delegate = self
        // The workspace preset runs a program here (claude) that drops back to a shell;
        // a plain toggle-open right drawer is just a shell.
        surface.start(
            rightDrawerCommand.map { ShellLaunch.program($0, cwd: focusedCWD) }
                ?? ShellLaunch.shell(cwd: focusedCWD))
        rightDrawerSurface = surface
        let panel = makeDrawerPanel(edge: .right, surface: surface)
        rightDrawerPanel = panel  // relayoutPanels() attaches it to `content`
        return panel
    }

    // MARK: lazygit float (⌘G)

    /// Toggle the lazygit float. When open, `⌘G` (and `⌘W`, and a backdrop click)
    /// hide it — the surface stays alive, so reopening is instant and preserves
    /// lazygit's view-state. When closed, it reveals the surface, first reloading it
    /// if the focused pane has moved to a different repo/dir since it was launched (so
    /// lazygit tracks the pane, never a stale directory). Mutually exclusive with zoom.
    func toggleLazygit() {
        if isLazygitOpen { hideLazygit(); return }
        guard gitRepoRoot(for: focusedCWD) != nil else {
            // lazygit is git-only: outside a repo it just dumps its "not a git repository"
            // prompt, so block it and say why instead.
            onRequestToast?(
                ToastContent(
                    variant: .info,
                    title: "Open Lazygit",
                    message: "lazygit needs a Git repository. Run `git init` here, "
                        + "or open a folder that has one."))
            return
        }
        exitZoomIfNeeded()  // zoom and the float are mutually exclusive
        if lazygitSurface != nil, lazygitAnchor(for: focusedCWD)?.path != lazygitLaunchAnchor?.path {
            discardLazygitSurface()  // focused pane moved repos → respawn at the current cwd
        }
        showLazygit(ensureLazygitSurface())
    }

    /// Eagerly spawn the lazygit surface in the background (no overlay shown) so the
    /// first `⌘G` reveals an already-loaded lazygit. Only for stable-path tabs, and only
    /// inside a repo — a plain tab's cwd drifts, and lazygit is useless off-repo anyway.
    private func prewarmLazygit() {
        guard gitRepoRoot(for: focusedCWD) != nil else { return }
        _ = ensureLazygitSurface()
    }

    /// A repo/workspace tab (opened via `⌘⇧P`, so `pinnedTitle` is set) has a fixed
    /// repo path worth keeping lazygit warm for. A plain `⌘t` tab does not.
    private var hasStablePath: Bool { pinnedTitle != nil }

    /// The enclosing git repo root for `cwd` — walks up looking for `RepoScanner.isGitRepo`
    /// — or nil when `cwd` isn't inside a repo.
    private func gitRepoRoot(for cwd: URL?) -> URL? {
        guard var dir = cwd?.standardizedFileURL else { return nil }
        while true {
            if RepoScanner.isGitRepo(dir) { return dir }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { return nil }  // reached the filesystem root
            dir = parent
        }
    }

    /// The identity lazygit is scoped to for `cwd`: the enclosing repo root (so cd'ing
    /// between a repo's own subdirs doesn't reload), else the plain cwd.
    private func lazygitAnchor(for cwd: URL?) -> URL? {
        gitRepoRoot(for: cwd) ?? cwd?.standardizedFileURL
    }

    /// The tab's lazygit surface, created on first use running `lazygit` via a login
    /// shell (so a Homebrew `lazygit` is on PATH — Epic 0's login-shell fix) in the
    /// focused pane's cwd. Mirrors `ensureBottomDrawerPanel()`.
    private func ensureLazygitSurface() -> TerminalSurface {
        if let existing = lazygitSurface { return existing }
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let surface = TerminalSurfaceFactory.make()
        surface.delegate = self
        // `-l -i`: a login AND interactive shell, so it sources BOTH profile files and
        // `.zshrc` — matching how lazygit runs when typed in a pane. Without `-i`, a
        // login-only shell skips `.zshrc`, so env it sets (e.g. XDG_CONFIG_HOME →
        // lazygit's config path, COLORTERM) is missing and lazygit renders different colors.
        surface.start(
            TerminalSurfaceConfig(
                command: shell, args: ["-l", "-i", "-c", "lazygit"],
                workingDirectory: focusedCWD, theme: Theme.rosePineMoon))
        lazygitSurface = surface
        lazygitLaunchAnchor = lazygitAnchor(for: focusedCWD)
        return surface
    }

    /// Terminate and drop the persisted surface. The ref is cleared BEFORE `terminate()`
    /// so a synchronous exit re-entry into `surfaceDidExit` is a no-op. Next reveal
    /// recreates it at the then-current cwd.
    private func discardLazygitSurface() {
        let surface = lazygitSurface
        lazygitSurface = nil
        lazygitLaunchAnchor = nil
        surface?.terminate()
    }

    /// Reveal the persisted surface: mount its overlay above the tab's tile and give
    /// it the tab's unified focus.
    private func showLazygit(_ surface: TerminalSurface) {
        // A prior overlay springing out still constrains `surface.view`; snap it away now so
        // reparenting into the new card doesn't leave the old card's constraints dangling.
        lazygitDismissingOverlay?.removeFromSuperview()
        lazygitDismissingOverlay = nil
        let overlay = LazygitOverlay(
            content: surface.view,
            background: Theme.rosePineMoon.background.nsColor,
            onDismiss: { [weak self] in self?.hideLazygit() })
        // Pin over the tile region (not `view`): covers only the tab's working area — never
        // the window gutters or the tab bar — above the canvas and any open drawers.
        presentTileOverlay(overlay)
        lazygitOverlay = overlay
        // Focus reads only on the float: clear the underlying panels' halos (keep
        // `focusedPanel` so hide can restore it).
        paneCanvas.setPanesFocused(false)
        bottomDrawerPanel?.isFocused = false
        rightDrawerPanel?.isFocused = false
        surface.focus()
        overlay.animateIn()
        onOverlayStateChanged?()  // lazygit now open → refresh the dock
    }

    /// Hide the float without killing lazygit — the surface persists for the next
    /// reveal. Dismiss paths (`⌘G`, `⌘W`, backdrop click) all land here.
    private func hideLazygit() {
        guard let overlay = lazygitOverlay else { return }
        // Nil the ref now so the modal gate lifts immediately (focus/dock update this
        // turn); the surface stays alive — only the card animates out and is removed.
        lazygitOverlay = nil
        // Hold the outgoing overlay until its exit finishes; a fast re-show snaps it early.
        lazygitDismissingOverlay = overlay
        overlay.animateOut { [weak self] in
            overlay.removeFromSuperview()
            if self?.lazygitDismissingOverlay === overlay { self?.lazygitDismissingOverlay = nil }
        }
        restoreUnifiedFocus()  // the float held keyboard focus; hand it back to its panel
        onOverlayStateChanged?()  // lazygit now closed → refresh the dock
    }

    /// Re-focus whichever panel held the tab's unified focus before the float opened
    /// (the float focuses its own surface without changing `focusedPanel`), restoring
    /// both the halo and keyboard first-responder.
    private func restoreUnifiedFocus() {
        switch focusedPanel {
        case .pane: paneCanvas.focusActivePane()
        case .bottomDrawer: focusDrawer(.bottom)
        case .rightDrawer: focusDrawer(.right)
        }
    }

    // MARK: tool floats (ephemeral command floats — diffnav, …)

    /// Toggle a tool float: same id open → close; otherwise run the guards and open a
    /// fresh surface. Mirrors `toggleLazygit`'s plumbing but spawns fresh each time.
    func toggleToolFloat(_ spec: ToolFloat) {
        if activeToolFloat?.spec.id == spec.id { closeToolFloat(); return }
        if activeToolFloat != nil { closeToolFloat() }  // switch floats
        if spec.requiresGitRepo, gitRepoRoot(for: focusedCWD) == nil {
            onRequestToast?(
                ToastContent(
                    variant: .info,
                    title: spec.title,
                    message: "This needs a Git repository. Run `git init` here, "
                        + "or open a folder that has one."))
            return
        }
        if let guardSpec = spec.emptyGuard, probeIsEmpty(guardSpec.probe) {
            onRequestToast?(guardSpec.toast)
            return
        }
        exitZoomIfNeeded()  // zoom and the float are mutually exclusive
        showToolFloat(spec)
    }

    /// Spawn `spec.command` in a fresh login+interactive shell at the focused cwd (so
    /// the user's git pager / PATH match a pane), present it in a `SurfaceFloatOverlay`,
    /// and give it the tab's unified focus. When the command exits, `surfaceDidExit`
    /// tears the float down.
    private func showToolFloat(_ spec: ToolFloat) {
        let shell = ShellLaunch.userShell
        let surface = TerminalSurfaceFactory.make()
        surface.delegate = self
        surface.start(
            TerminalSurfaceConfig(
                command: shell, args: ["-l", "-i", "-c", spec.command],
                workingDirectory: focusedCWD, theme: Theme.rosePineMoon))
        let overlay = SurfaceFloatOverlay(
            content: surface.view,
            background: Theme.rosePineMoon.background.nsColor,
            widthFraction: spec.widthFraction,
            heightFraction: spec.heightFraction,
            contentInset: 10,
            cornerRadius: 14,
            onDismiss: { [weak self] in self?.closeToolFloat() })
        presentTileOverlay(overlay)
        activeToolFloat = (spec, surface, overlay)
        paneCanvas.setPanesFocused(false)
        bottomDrawerPanel?.isFocused = false
        rightDrawerPanel?.isFocused = false
        surface.focus()
        overlay.animateIn()
        onOverlayStateChanged?()
    }

    /// Close the float and TERMINATE its surface (ephemeral — no persistence). Clears
    /// the slot before terminate so a synchronous `surfaceDidExit` re-entry no-ops.
    func closeToolFloat() {
        guard let active = activeToolFloat else { return }
        activeToolFloat = nil
        let overlay = active.overlay
        overlay.animateOut { overlay.removeFromSuperview() }
        active.surface.terminate()
        restoreUnifiedFocus()
        onOverlayStateChanged?()
    }

    /// The empty-guard probe's timeout — the toggle path blocks on it, so a pathological
    /// probe can't freeze the UI. On timeout we fail open (show the float).
    private static let probeTimeout: TimeInterval = 2

    /// Run `probe` as a plain (non-login) shell at the focused cwd; exit 0 ⇒ nothing to show.
    /// Used by a float's `emptyGuard` to toast instead of opening an empty float. Bounded by
    /// `probeTimeout` and fail-open on any error/timeout so it never blocks or wrongly guards.
    private func probeIsEmpty(_ probe: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ShellLaunch.userShell)
        process.arguments = ["-c", probe]
        process.currentDirectoryURL = focusedCWD ?? ShellLaunch.defaultCWD
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return false  // couldn't probe → don't block opening the float
        }
        // Wait on a background queue (it keeps `process` alive and reaps the child even on the
        // timeout path); the main thread blocks only up to `probeTimeout`.
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            process.waitUntilExit()
            finished.signal()
        }
        if finished.wait(timeout: .now() + Self.probeTimeout) == .timedOut {
            process.terminate()  // fail open; the background wait then reaps it
            return false
        }
        return process.terminationStatus == 0
    }

    // MARK: tiling

    private func makeDrawerPanel(edge: DrawerEdge, surface: TerminalSurface) -> PanelHostView {
        // Headers dropped for now — drawers use the bare pane chrome (meta: nil). A
        // corner hide button (chevron pointing the way it collapses) toggles the drawer.
        let hideSymbol = edge == .bottom ? "chevron.down" : "chevron.right"
        let hideLabel = edge == .bottom ? "Hide bottom drawer" : "Hide right drawer"
        let panel = PanelHostView(
            content: surface.view,
            background: Theme.rosePineMoon.background.nsColor,
            meta: nil,
            hideButton: (
                symbol: hideSymbol, label: hideLabel,
                onHide: { [weak self] in
                    switch edge {
                    case .bottom: self?.toggleBottomDrawer()
                    case .right: self?.toggleRightDrawer()
                    }
                }
            ),
            onFocusRequest: { [weak self] in self?.focusDrawer(edge) })
        panel.onZoomExit = { [weak self] in self?.toggleZoom() }
        panel.translatesAutoresizingMaskIntoConstraints = false
        return panel
    }

    /// Give the given drawer the tab's single unified focus/halo: yield the pane
    /// canvas's halo, mark this drawer's panel focused and the other unfocused, and
    /// move terminal keyboard focus to its surface.
    private func focusDrawer(_ edge: DrawerEdge) {
        let surface: TerminalSurface?
        switch edge {
        case .bottom:
            focusedPanel = .bottomDrawer
            bottomDrawerPanel?.isFocused = true
            rightDrawerPanel?.isFocused = false
            surface = bottomDrawerSurface
        case .right:
            focusedPanel = .rightDrawer
            rightDrawerPanel?.isFocused = true
            bottomDrawerPanel?.isFocused = false
            surface = rightDrawerSurface
        }
        paneCanvas.setPanesFocused(false)
        surface?.focus()
        onFocusChanged?()  // a drawer click also steals focus from a confirm — void it
    }

    /// Restore focus after closing a focused drawer: to the other drawer if it's still
    /// open, else the pane. With only two drawers + the pane, the focus before this drawer
    /// was opened was necessarily the pane or the other drawer — and whether that other
    /// drawer is still open is exactly the discriminator, so this reconstructs it.
    private func restoreFocusAfterClosingDrawer(otherOpen: Bool, other: DrawerEdge) {
        if otherOpen { focusDrawer(other) } else { paneCanvas.focusActivePane() }
    }

    /// The pane canvas (re)gained focus — reassert unified focus onto it: it holds
    /// the tab's single halo again and both drawer panels go unfocused.
    private func paneGainedFocus() {
        focusedPanel = .pane
        paneCanvas.setPanesFocused(true)
        bottomDrawerPanel?.isFocused = false
        rightDrawerPanel?.isFocused = false
        onFocusChanged?()
    }

    // MARK: zoom (⌘F)

    /// Zoom the focused panel to fill the tab (others hidden), or unzoom if already
    /// zoomed. For a pane, the pane canvas also renders just the focused leaf.
    func toggleZoom() {
        guard !isLazygitOpen else { return }  // can't zoom a panel under the float
        if isZoomed { exitZoom(); return }
        switch focusedPanel {
        case .pane:
            paneCanvas.zoomFocusedLeaf()
            zoomedPanel = .pane
        case .bottomDrawer:
            guard isBottomOpen, bottomDrawerPanel != nil else { return }
            bottomDrawerPanel?.isZoomed = true
            zoomedPanel = .bottomDrawer
        case .rightDrawer:
            guard isRightOpen, rightDrawerPanel != nil else { return }
            rightDrawerPanel?.isZoomed = true
            zoomedPanel = .rightDrawer
        }
        relayoutPanels()
    }

    private func exitZoom() {
        switch zoomedPanel {
        case .pane: paneCanvas.unzoom()
        case .bottomDrawer, .rightDrawer:
            bottomDrawerPanel?.isZoomed = false
            rightDrawerPanel?.isZoomed = false
        case nil: return
        }
        zoomedPanel = nil
        relayoutPanels()
    }

    /// Unzoom if zoomed; returns true if it did. (Shared with PR3's Escape handling.)
    @discardableResult func exitZoomIfNeeded() -> Bool {
        if isZoomed { exitZoom(); return true }
        return false
    }

    // MARK: cross-panel spatial nav (⌘hjkl)

    /// Sentinel ids standing in for the drawer panels in the shared nav graph —
    /// pane leaf ids are always non-negative, so these can't collide with a real
    /// `PaneID`.
    private static let bottomDrawerID = PaneID(Int.min)
    private static let rightDrawerID = PaneID(Int.min + 1)

    /// Directional focus memory: `navReturn[panel][direction]` is the panel last left to
    /// reach `panel` by moving the opposite way — so the reverse hop returns there instead
    /// of whatever the geometric scorer picks. Used only when that panel is still open and
    /// actually lies in `direction`; else nav falls back to nearest-neighbor. Pane ids are
    /// never reused, so stale entries can't mis-target — they just fail the checks.
    private var navReturn: [PaneID: [Direction: PaneID]] = [:]

    /// Move the tab's unified focus to the nearest panel — pane or open drawer — in
    /// `direction`. Pane leaf frames and any open drawer's frame are scored together
    /// by PaneKit's `nearestLeaf`, the same geometric scorer pane-to-pane nav already
    /// uses, so a drawer is just another panel in the graph.
    func navigate(_ direction: Direction) {
        if exitZoomIfNeeded() { return }  // ⌘hjkl while zoomed just unzooms
        var frames = paneCanvas.leafFrames(in: content)
        if isBottomOpen, let panel = bottomDrawerPanel {
            frames[Self.bottomDrawerID] = flippedFrame(of: panel)
        }
        if isRightOpen, let panel = rightDrawerPanel {
            frames[Self.rightDrawerID] = flippedFrame(of: panel)
        }

        let origin = currentPanelID
        // Prefer the panel we last came from when leaving `origin` this way, so hopping back
        // and forth (esp. pane ↔ drawer) returns to where you were rather than whatever the
        // geometric scorer picks — but only when it's still open and genuinely lies in
        // `direction`; otherwise fall back to nearest-neighbor.
        let remembered = navReturn[origin]?[direction]
        let target =
            (remembered.map { isPanel($0, inDirection: direction, from: origin, frames: frames) } == true)
            ? remembered
            : nearestLeaf(from: origin, frames: frames, direction: direction)
        guard let target else { return }

        navReturn[target, default: [:]][direction.opposite] = origin  // enable the return hop
        focusPanel(target)
    }

    /// The id of the panel that currently holds unified focus, in the shared nav id space.
    private var currentPanelID: PaneID {
        switch focusedPanel {
        case .pane: return paneCanvas.focusedLeafID
        case .bottomDrawer: return Self.bottomDrawerID
        case .rightDrawer: return Self.rightDrawerID
        }
    }

    /// Move unified focus to the panel with `id` (a drawer sentinel or a pane leaf).
    /// `focusLeaf` bubbles through `paneCanvas.onFocusChanged` → `paneGainedFocus()`, which
    /// reasserts unified focus (halo + panel routing) onto the pane canvas.
    private func focusPanel(_ id: PaneID) {
        if id == Self.bottomDrawerID {
            focusDrawer(.bottom)
        } else if id == Self.rightDrawerID {
            focusDrawer(.right)
        } else {
            paneCanvas.focusLeaf(id)
        }
    }

    /// Whether `candidate` lies in `direction` from `origin`, using the same y-flipped
    /// frames and thresholds as `nearestLeaf` — so a remembered return target is only used
    /// when it's still spatially in that direction.
    private func isPanel(
        _ candidate: PaneID, inDirection direction: Direction,
        from origin: PaneID, frames: [PaneID: CGRect]
    ) -> Bool {
        guard let s = frames[origin], let r = frames[candidate] else { return false }
        let dx = r.midX - s.midX
        let dy = r.midY - s.midY
        switch direction {
        case .left: return dx < -4
        case .right: return dx > 4
        case .up: return dy < -4
        case .down: return dy > 4
        }
    }

    /// Resize whichever panel holds focus by moving its edge in `direction`. For a pane
    /// this defers to the pane canvas's edge-aware resize. A docked drawer only resizes
    /// along its own axis, growing toward the canvas: the bottom drawer grows up (⌘⇧K) and
    /// shrinks down (⌘⇧J); the right drawer grows left into the canvas (⌘⇧H) and shrinks
    /// right (⌘⇧L) — the same feel as an edge pane on that side. The cross axis beeps. A
    /// resize chord while zoomed just unzooms, matching `navigate`.
    func resize(_ direction: Direction) {
        if exitZoomIfNeeded() { return }
        switch focusedPanel {
        case .pane:
            paneCanvas.resize(direction)
        case .bottomDrawer:
            switch direction {
            case .up:
                bottomDrawerHeight = clampedDrawerExtent(
                    bottomDrawerHeight + Self.drawerResizeStep, along: content.bounds.height)
            case .down:
                bottomDrawerHeight = clampedDrawerExtent(
                    bottomDrawerHeight - Self.drawerResizeStep, along: content.bounds.height)
            case .left, .right: NSSound.beep(); return
            }
            relayoutPanels()
        case .rightDrawer:
            switch direction {
            case .left:
                rightDrawerWidth = clampedDrawerExtent(
                    rightDrawerWidth + Self.drawerResizeStep, along: content.bounds.width)
            case .right:
                rightDrawerWidth = clampedDrawerExtent(
                    rightDrawerWidth - Self.drawerResizeStep, along: content.bounds.width)
            case .up, .down: NSSound.beep(); return
            }
            relayoutPanels()
        }
    }

    /// Clamp a drawer extent to `[minDrawerExtent, maxDrawerFraction · working axis]`, with
    /// the ceiling floored at `minDrawerExtent` so that on a very small window the range
    /// can't invert (the floor always wins over an even smaller fractional ceiling).
    private func clampedDrawerExtent(_ value: CGFloat, along axis: CGFloat) -> CGFloat {
        let ceiling = max(Self.minDrawerExtent, axis * Self.maxDrawerFraction)
        return min(max(value, Self.minDrawerExtent), ceiling)
    }

    /// A drawer panel's frame converted into `content` coords and flipped the same
    /// way `PaneCanvasController.leafFrames(in:)` flips pane frames (top-left origin,
    /// relative to `content`'s own height), so the two frame sets score uniformly in
    /// `nearestLeaf`.
    private func flippedFrame(of panel: NSView) -> CGRect {
        let f = panel.convert(panel.bounds, to: content)
        let h = content.bounds.height
        return CGRect(x: f.minX, y: h - f.maxY, width: f.width, height: f.height)
    }

    /// Rebuild the tile layout from `isBottomOpen`/`isRightOpen`: the canvas + any
    /// open drawer panels as sibling panels within `content`, separated by a
    /// `ChromeMetrics.panelGap` gutter, never overlapping. Right drawer is a full-height column; bottom
    /// drawer sits under the canvas in the remaining left column (never under the
    /// right column). Deactivates the previous tile constraint set before activating
    /// the new one so repeated toggles never accumulate constraints.
    private func zoomedView(_ ref: PanelRef) -> NSView? {
        switch ref {
        case .pane: return canvas
        case .bottomDrawer: return bottomDrawerPanel
        case .rightDrawer: return rightDrawerPanel
        }
    }

    /// Attach a panel to `content` (visible) or detach it (hidden). Hidden panels are
    /// DETACHED, not `isHidden` — a hidden view kept in the layout collapses to a 0×0
    /// frame, which resizes its PTY to 0 columns and crashes size-sensitive TUIs (e.g.
    /// a turborepo dev server). Detached, the terminal keeps its last size (process
    /// alive), exactly like a backgrounded pane; reattaching restores a valid size.
    private func setAttached(_ view: NSView, _ attached: Bool) {
        if attached {
            if view.superview !== content { content.addSubview(view) }
        } else if view.superview === content {
            view.removeFromSuperview()
        }
    }

    /// Seed the drawer sizes from the working area the first time `content` has a real
    /// size — a third of it, capped. Runs once; later manual resizes (⌥-arrows) own the
    /// value from then on.
    private func seedDrawerSizesIfNeeded() {
        guard !didSeedDrawerSizes, content.bounds.height > 0, content.bounds.width > 0 else { return }
        didSeedDrawerSizes = true
        bottomDrawerHeight = min(content.bounds.height * Self.bottomDrawerFraction, Self.bottomDrawerMax)
        rightDrawerWidth = min(content.bounds.width * Self.rightDrawerFraction, Self.rightDrawerMax)
    }

    private func relayoutPanels() {
        seedDrawerSizesIfNeeded()
        NSLayoutConstraint.deactivate(tileConstraints)
        tileConstraints = []

        // The zoom target is only effective while its view exists (a zoomed drawer
        // whose shell just exited falls back to normal tiling).
        let effectiveZoom: PanelRef? = zoomedPanel.flatMap { zoomedView($0) != nil ? $0 : nil }

        let canvasVisible: Bool
        let bottomVisible: Bool
        let rightVisible: Bool
        if let z = effectiveZoom {
            canvasVisible = z == .pane
            bottomVisible = z == .bottomDrawer
            rightVisible = z == .rightDrawer
        } else {
            canvasVisible = true
            bottomVisible = isBottomOpen
            rightVisible = isRightOpen
        }
        setAttached(canvas, canvasVisible)
        if let p = bottomDrawerPanel { setAttached(p, bottomVisible) }
        if let p = rightDrawerPanel { setAttached(p, rightVisible) }

        // Zoom: the single visible panel fills `content`.
        if let z = effectiveZoom, let zv = zoomedView(z) {
            let cs = [
                zv.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                zv.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                zv.topAnchor.constraint(equalTo: content.topAnchor),
                zv.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            ]
            NSLayoutConstraint.activate(cs)
            tileConstraints = cs
            return
        }

        // Normal tiling among the visible panels (canvas always visible here).
        var cs: [NSLayoutConstraint] = [
            canvas.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            canvas.topAnchor.constraint(equalTo: content.topAnchor),
        ]

        if isRightOpen, let rightPanel = rightDrawerPanel {
            // `.defaultHigh` (not required) so on an extremely small window this
            // constraint relaxes instead of forcing the canvas to a negative size and
            // logging a broken-constraint error — the drawer shrinks under squeeze.
            let width = rightPanel.widthAnchor.constraint(equalToConstant: rightDrawerWidth)
            width.priority = .defaultHigh
            cs += [
                rightPanel.topAnchor.constraint(equalTo: content.topAnchor),
                rightPanel.bottomAnchor.constraint(equalTo: content.bottomAnchor),
                rightPanel.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                width,
                canvas.trailingAnchor.constraint(equalTo: rightPanel.leadingAnchor, constant: -ChromeMetrics.panelGap),
            ]
        } else {
            cs.append(canvas.trailingAnchor.constraint(equalTo: content.trailingAnchor))
        }

        if isBottomOpen, let bottomPanel = bottomDrawerPanel {
            // See the right-drawer width constraint above: same rationale for height.
            let height = bottomPanel.heightAnchor.constraint(equalToConstant: bottomDrawerHeight)
            height.priority = .defaultHigh
            cs += [
                bottomPanel.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                bottomPanel.bottomAnchor.constraint(equalTo: content.bottomAnchor),
                height,
                canvas.bottomAnchor.constraint(equalTo: bottomPanel.topAnchor, constant: -ChromeMetrics.panelGap),
            ]
            // The bottom drawer spans the canvas column only — it stops short of the
            // right drawer's column, so the two never overlap when both are open.
            if isRightOpen, let rightPanel = rightDrawerPanel {
                cs.append(
                    bottomPanel.trailingAnchor.constraint(
                        equalTo: rightPanel.leadingAnchor, constant: -ChromeMetrics.panelGap))
            } else {
                cs.append(bottomPanel.trailingAnchor.constraint(equalTo: content.trailingAnchor))
            }
        } else {
            cs.append(canvas.bottomAnchor.constraint(equalTo: content.bottomAnchor))
        }

        NSLayoutConstraint.activate(cs)
        tileConstraints = cs
    }
}

extension TabController: TerminalSurfaceDelegate {
    /// A click landed in one of the tab's drawer surfaces — give that drawer unified
    /// focus. The lazygit float is modal and already holds focus, so it's ignored.
    func surfaceWantsFocus(_ s: TerminalSurface) {
        if s === bottomDrawerSurface { focusDrawer(.bottom) } else if s === rightDrawerSurface { focusDrawer(.right) }
    }
    /// A drawer's shell exited on its own (e.g. the user typed `exit`): close+clear
    /// that drawer entirely — rather than leaving a dead shell docked — so the next
    /// toggle lazily spawns a fresh one. Panes have their own exit handling in
    /// `PaneCanvasController`; this only reacts to the two drawer surfaces.
    func surfaceDidExit(_ s: TerminalSurface, code: Int32?) {
        if let active = activeToolFloat, s === active.surface {
            // The tool ran to completion / quit (`q` in diffnav) → close the float.
            activeToolFloat = nil
            active.overlay.animateOut { active.overlay.removeFromSuperview() }
            active.surface.terminate()
            restoreUnifiedFocus()
            onOverlayStateChanged?()
            return
        }
        if s === lazygitSurface {
            // lazygit quit (`q`): the process is gone. Animate the card out (matching a
            // ⌘G hide) and drop the surface.
            let wasVisible = isLazygitOpen
            if let overlay = lazygitOverlay {
                lazygitOverlay = nil
                overlay.animateOut { overlay.removeFromSuperview() }
            }
            discardLazygitSurface()  // clears the ref before terminate (re-entry no-ops)
            if wasVisible {
                restoreUnifiedFocus()
                // Re-warm only for a stable-path tab still inside a repo, and only after a
                // VISIBLE quit: an instantly-exiting surface (lazygit not on PATH, or a
                // drifted non-repo cwd) exits while hidden, so it can never spin a respawn
                // loop. Plain tabs respawn on the next ⌘G.
                if hasStablePath, gitRepoRoot(for: focusedCWD) != nil { _ = ensureLazygitSurface() }
            }
            onOverlayStateChanged?()
            return
        }
        if s === bottomDrawerSurface {
            if zoomedPanel == .bottomDrawer { zoomedPanel = nil }  // don't leave zoom stuck
            bottomDrawerPanel?.removeFromSuperview()
            bottomDrawerSurface?.terminate()
            bottomDrawerSurface = nil
            bottomDrawerPanel = nil
            isBottomOpen = false
            relayoutPanels()
            // `focusActivePane()` restores BOTH the pane's keyboard first-responder
            // and — via `onFocusChanged` → `paneGainedFocus()` — the unified halo/
            // routing state, so typing `exit` in a focused drawer doesn't orphan
            // keystrokes until the next click. But NOT while the modal float is open:
            // it must keep focus, so only re-point `focusedPanel` to the pane (the
            // now-gone drawer) so closing the float later restores focus correctly.
            if focusedPanel == .bottomDrawer {
                if isLazygitOpen { focusedPanel = .pane } else { paneCanvas.focusActivePane() }
            }
        } else if s === rightDrawerSurface {
            if zoomedPanel == .rightDrawer { zoomedPanel = nil }  // don't leave zoom stuck
            rightDrawerPanel?.removeFromSuperview()
            rightDrawerSurface?.terminate()
            rightDrawerSurface = nil
            rightDrawerPanel = nil
            isRightOpen = false
            relayoutPanels()
            // See the bottom-drawer branch above: keep the modal float focused if open,
            // otherwise restore keyboard focus + unified halo/routing to the pane.
            if focusedPanel == .rightDrawer {
                if isLazygitOpen { focusedPanel = .pane } else { paneCanvas.focusActivePane() }
            }
        }
    }
}
