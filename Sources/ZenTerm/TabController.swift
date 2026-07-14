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
    /// Whether each drawer's shell has a live process — drives the footer dock's activity dot
    /// when the drawer is hidden (ZEN-107).
    var bottomBusy = false
    var rightBusy = false
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

    // Drawer sizes are stored as a FRACTION of the tab's working area — not absolute pixels —
    // and applied as a multiplier constraint, so a drawer stays proportional through window
    // resizes exactly like a pane. Seeded from the config default; manual ⌥-resize updates the
    // fraction from then on. These knobs are user-overridable via `~/.config/zen-term/config`
    // (`bottom-drawer-fraction`, `right-drawer-fraction`, `drawer-resize-step`,
    // `max-drawer-fraction`).
    private static var bottomDrawerFraction: CGFloat { GeneralConfig.current.bottomDrawerFraction }
    private static var rightDrawerFraction: CGFloat { GeneralConfig.current.rightDrawerFraction }
    private var bottomDrawerRatio = min(
        TabController.bottomDrawerFraction, TabController.maxDrawerFraction)
    private var rightDrawerRatio = min(
        TabController.rightDrawerFraction, TabController.maxDrawerFraction)
    /// One ⌥-arrow nudge for a focused drawer, and the floor it can shrink to. A drawer is
    /// capped at `maxDrawerFraction` of the working axis (default 0.7) — except on a very
    /// small window, where the `minDrawerExtent` px floor wins and can exceed that fraction.
    private static var drawerResizeStep: CGFloat { GeneralConfig.current.drawerResizeStep }
    private static let minDrawerExtent: CGFloat = 160
    private static var maxDrawerFraction: CGFloat { GeneralConfig.current.maxDrawerFraction }

    // Per-tab auxiliary surfaces (created lazily; kept alive when hidden — the shell
    // persists across toggles and is only terminated in `shutdown()`).
    private var bottomDrawerSurface: TerminalSurface?
    private var bottomDrawerPanel: PanelHostView?
    private var isBottomOpen = false { didSet { onOverlayStateChanged?() } }
    /// The nav token minted for the drawer's shell (exported as `$ZEN_PANE`), so an nvim
    /// inside a drawer participates in seamless nav just like one in a pane.
    private var bottomDrawerToken: Int?

    private var rightDrawerSurface: TerminalSurface?
    private var rightDrawerPanel: PanelHostView?
    private var isRightOpen = false { didSet { onOverlayStateChanged?() } }
    private var rightDrawerToken: Int?

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
    /// The pending debounced pre-warm (ZEN-55): scheduling off the `applyRecipe` turn
    /// keeps a workspace open from bursting four login shells at once. Canceled by
    /// `shutdown()` and by `showLazygit` (a `⌘G` that beats the timer supersedes it).
    private var prewarmWorkItem: DispatchWorkItem?
    /// Debounce delay and LRU cap for the pre-warm (ZEN-55). Injected at init like
    /// `makeSurface` — immutable so a mid-flight reassignment can't strand a pooled
    /// entry (a stale pool would later evict a surface this tab no longer tracks).
    private let prewarmDelay: TimeInterval
    private let prewarmPool: LazygitPrewarmPool

    /// The single live ephemeral tool float (diffnav, …). Tool floats are modal and
    /// mutually exclusive, so one slot suffices. Terminated on close (not persisted).
    private var activeToolFloat: (spec: ToolFloat, surface: TerminalSurface, overlay: SurfaceFloatOverlay)?
    var isToolFloatOpen: Bool { activeToolFloat != nil }
    /// The float id whose empty-guard probe is currently deciding (async). A re-press while a
    /// probe is in flight is ignored, so a double-tap can't spawn two overlapping floats.
    private var probingToolFloatID: String?
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

    /// Bumped on each animated drawer toggle so a superseded animation's completion (fired ~a beat
    /// later) can't stomp the layout a newer toggle already owns. One counter per edge.
    private var bottomDrawerAnimationID = 0
    private var rightDrawerAnimationID = 0

    /// How many drawer slides are mid-flight. `content` is clipped while any is running (a drawer
    /// parks just outside the content bounds before sliding in); the clip is lifted only when the
    /// last one finishes, so a bottom + right pair can't unclip each other early.
    private var activeDrawerSlides = 0

    /// The four window-gutter content-inset constraints, kept so a config change can re-apply the
    /// gutter to this already-built tab (see `reapplyChromeLayout()`).
    private var gutterConstraints: [NSLayoutConstraint] = []

    var onTitleChanged: (() -> Void)? {
        get { paneCanvas.onTitleChanged }
        set { paneCanvas.onTitleChanged = newValue }
    }
    var onLastPaneClosed: (() -> Void)? {
        get { paneCanvas.onLastPaneClosed }
        set { paneCanvas.onLastPaneClosed = newValue }
    }

    /// A pinned tab name (set when opened via the `⌘P` repo picker): overrides the
    /// live cwd-derived title so the tab keeps the workspace's name no matter where the
    /// focused pane's shell `cd`s. Nil for tabs opened any other way.
    var pinnedTitle: String?
    var title: String { pinnedTitle ?? paneCanvas.title }
    var focusedCWD: URL? { paneCanvas.focusedCWD }

    /// True when the tab has a single pane, so ⌘W on it would close the whole tab.
    var isSinglePane: Bool { paneCanvas.paneCount == 1 }

    /// Every live terminal surface this tab owns: the split-pane surfaces (via the canvas) plus
    /// the auxiliary drawer/lazygit/tool-float surfaces. Used to re-theme all surfaces live on a
    /// config change.
    var allSurfaces: [TerminalSurface] {
        var result = paneCanvas.allSurfaces
        result.append(
            contentsOf: [bottomDrawerSurface, rightDrawerSurface, lazygitSurface, activeToolFloat?.surface]
                .compactMap { $0 })
        return result
    }

    /// Whether the focused main-canvas pane has a running process.
    var focusedPaneIsBusy: Bool { paneCanvas.focusedPaneIsBusy }
    // Whether the *focused* panel is running nvim, so the key guard passes ctrl-nav through to
    // it. Keyed off the focused panel, not just the pane canvas: a drawer isn't a leaf, so when
    // one holds focus `paneCanvas.focusedLeaf` still points at the last pane — reading it would
    // treat a drawer as the nvim pane. Each panel reports its own token's vim state.
    var focusedPaneIsVim: Bool {
        switch focusedPanel {
        case .pane: return paneCanvas.focusedPaneIsVim
        case .bottomDrawer, .rightDrawer:
            return drawerToken(focusedPanel).map(NavRegistry.shared.isVim) ?? false
        }
    }

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
            zoomed: zoomedPanel.map(\.asZoomed),
            bottomBusy: bottomDrawerSurface?.isBusy == true,
            rightBusy: rightDrawerSurface?.isBusy == true)
    }
    var onOverlayStateChanged: (() -> Void)?

    /// Request a transient top-right toast (e.g. `⌘G` blocked outside a git repo).
    var onRequestToast: ((ToastContent) -> Void)?

    /// The tab's focused surface changed (a pane or drawer click, or spatial nav). Lets a
    /// host void a pending close confirm whose target/modality just moved out from under it.
    var onFocusChanged: (() -> Void)?

    /// Any of the tab's surfaces posted a desktop notification (OSC 777) — the
    /// message-bearing "needs attention" signal the `WindowController` latches onto the tab.
    var onNotification: ((TerminalNotification) -> Void)?

    /// A startup command for the right drawer (a workspace recipe's `right`, e.g. `claude`).
    /// When set, opening the right drawer launches the program-then-shell recipe instead of a
    /// plain shell. Nil → plain shell. The sentinel `"shell"` also means a plain shell.
    var rightDrawerCommand: String?

    /// A startup command for the bottom drawer (a workspace recipe's `bottom`). Same semantics
    /// as `rightDrawerCommand`: a command runs program-then-shell; nil or `"shell"` → plain shell.
    var bottomDrawerCommand: String?

    /// A workspace recipe's environment, injected into every pane and drawer of this tab.
    private let workspaceEnv: [String: String]

    /// How this tab spawns terminal surfaces — the backend seam, injectable so tests
    /// can count spawns/terminations without a real backend (mirrors `PaneCanvasController`).
    private let makeSurface: () -> TerminalSurface

    init(
        initialCWD: URL?, initialCommand: String? = nil, env: [String: String] = [:],
        makeSurface: @escaping () -> TerminalSurface = TerminalSurfaceFactory.make,
        prewarmPool: LazygitPrewarmPool = .shared, prewarmDelay: TimeInterval = 1.0
    ) {
        workspaceEnv = env
        self.makeSurface = makeSurface
        self.prewarmPool = prewarmPool
        self.prewarmDelay = prewarmDelay
        paneCanvas = PaneCanvasController(
            initialCWD: initialCWD, initialCommand: initialCommand, env: env,
            makeSurface: makeSurface)
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
        gutterConstraints = [
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: ChromeMetrics.windowGutter),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -ChromeMetrics.windowGutter),
            content.topAnchor.constraint(equalTo: view.topAnchor, constant: ChromeMetrics.windowGutter),
            content.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -ChromeMetrics.windowGutter),
        ]
        NSLayoutConstraint.activate(gutterConstraints)
        content.addSubview(canvas)
        relayoutPanels()

        paneCanvas.onFocusChanged = { [weak self] in self?.paneGainedFocus() }
        paneCanvas.onPanesRemoved = { [weak self] closed in self?.pruneNavReturn(closed: closed) }
        paneCanvas.onSocketFocus = { [weak self] dir in self?.navigate(dir) }
        paneCanvas.onZoomEnded = { [weak self] in self?.paneZoomEndedInternally() }
        paneCanvas.onNotification = { [weak self] n in self?.onNotification?(n) }
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
    func split(_ axis: SplitAxis) {
        if isZoomed { toastZoomBlocked("split"); return }
        paneCanvas.split(axis)
    }
    @discardableResult func closeFocused() -> Bool {
        exitZoomIfNeeded()  // exit zoom before closing so zoom state can't desync
        return paneCanvas.closeFocused()
    }
    func focusActivePane() { paneCanvas.focusActivePane() }

    /// Apply a workspace's open recipe: reveal only the drawers the recipe names (each running
    /// its configured command, via `rightDrawerCommand`/`bottomDrawerCommand` set before this),
    /// land focus on the requested region, and pre-warm lazygit for the stable cwd. Called once
    /// right after `start()` for a workspace-opened tab. A recipe naming no drawers leaves a
    /// single pane with both drawers collapsed — the minimal default.
    func applyRecipe(_ ws: Workspace) {
        if ws.right != nil, !isRightOpen { toggleRightDrawer() }
        if ws.bottom != nil, !isBottomOpen { toggleBottomDrawer() }
        switch ws.focus {
        case .right where isRightOpen: focusDrawer(.right)
        case .bottom where isBottomOpen: focusDrawer(.bottom)
        default: focusActivePane()  // main, or a named drawer the recipe didn't open
        }
        schedulePrewarmLazygit()  // workspace tab has a stable cwd → pre-warm so the first ⌘G is instant
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
        prewarmWorkItem?.cancel()
        prewarmWorkItem = nil
        paneCanvas.shutdown()
        bottomDrawerSurface?.terminate()
        bottomDrawerSurface = nil
        unregisterDrawerToken(.bottomDrawer)
        rightDrawerSurface?.terminate()
        rightDrawerSurface = nil
        unregisterDrawerToken(.rightDrawer)
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
        switch zoomedPanel {
        case .pane, .bottomDrawer:
            toastZoomBlocked("toggle a drawer")  // zoom is strict — only ⌘F exits
            return
        case .rightDrawer:
            switchZoomedDrawer(to: .bottom)  // jump the zoom to the other drawer
            return
        case nil:
            break  // not zoomed — fall through to the normal toggle
        }
        isBottomOpen.toggle()
        // Reduce Motion falls back to the instant constraint swap; we're already past the zoom
        // guards above, so a plain toggle here animates the real-layout push.
        let animate = !Motion.isReduceMotionEnabled()
        if isBottomOpen {
            _ = ensureBottomDrawerPanel()
            if animate { animateBottomDrawer(opening: true) } else { relayoutPanels() }
            focusDrawer(.bottom)
        } else {
            if animate { animateBottomDrawer(opening: false) } else { relayoutPanels() }
            // Only restore focus if the drawer being hidden held unified focus — to the
            // other drawer if it's still open, else the pane.
            if focusedPanel == .bottomDrawer { restoreFocusAfterClosingDrawer(otherOpen: isRightOpen, other: .right) }
        }
    }

    private func ensureBottomDrawerPanel() -> PanelHostView {
        if let existing = bottomDrawerPanel { return existing }
        let surface = makeSurface()
        surface.delegate = self
        let token = registerDrawerToken(.bottomDrawer)
        bottomDrawerToken = token
        surface.start(drawerConfig(command: bottomDrawerCommand, token: token))
        bottomDrawerSurface = surface
        let panel = makeDrawerPanel(edge: .bottom, surface: surface)
        bottomDrawerPanel = panel  // relayoutPanels() attaches it to `content`
        return panel
    }

    /// A drawer's launch config: a workspace recipe command runs program-then-shell; nil or the
    /// sentinel `"shell"` opens a plain shell. The workspace env is injected either way.
    private func drawerConfig(command: String?, token: Int) -> TerminalSurfaceConfig {
        let env = NavSocketServer.env(base: workspaceEnv, token: token)
        if let command, command != "shell" {
            return ShellLaunch.program(command, cwd: focusedCWD, env: env)
        }
        return ShellLaunch.shell(cwd: focusedCWD, env: env)
    }

    /// This tab's live token for a drawer panel, or nil for a closed/exited drawer or `.pane`.
    private func drawerToken(_ panel: PanelRef) -> Int? {
        switch panel {
        case .bottomDrawer: return bottomDrawerToken
        case .rightDrawer: return rightDrawerToken
        case .pane: return nil
        }
    }

    /// Mint and register a nav token for a drawer's shell, so an nvim inside it hands off over
    /// the socket like a pane does. The route fires only while this drawer holds focus AND the
    /// token is still current — the drawer analog of the pane route's focused-token check, so a
    /// stale command for an exited-then-reopened drawer can't drive navigation.
    private func registerDrawerToken(_ panel: PanelRef) -> Int {
        let token = NavRegistry.shared.mintToken()
        NavRegistry.shared.register(token: token) { [weak self] dir in
            guard let self, self.focusedPanel == panel, self.drawerToken(panel) == token else { return }
            self.navigate(dir)
        }
        return token
    }

    /// Release a drawer's nav token when its shell dies (self-exit or tab teardown), matching
    /// the surface's lifetime so `NavRegistry` never keeps an orphaned route or vim flag.
    private func unregisterDrawerToken(_ panel: PanelRef) {
        switch panel {
        case .bottomDrawer:
            bottomDrawerToken.map(NavRegistry.shared.unregister)
            bottomDrawerToken = nil
        case .rightDrawer:
            rightDrawerToken.map(NavRegistry.shared.unregister)
            rightDrawerToken = nil
        case .pane:
            break
        }
    }

    // MARK: right drawer (⌘|)

    /// Toggle the right drawer. First open creates a persistent login-shell surface
    /// in the tab's cwd; toggling hidden keeps it running; it dies only in `shutdown()`.
    func toggleRightDrawer() {
        switch zoomedPanel {
        case .pane, .rightDrawer:
            toastZoomBlocked("toggle a drawer")  // zoom is strict — only ⌘F exits
            return
        case .bottomDrawer:
            switchZoomedDrawer(to: .right)  // jump the zoom to the other drawer
            return
        case nil:
            break  // not zoomed — fall through to the normal toggle
        }
        isRightOpen.toggle()
        let animate = !Motion.isReduceMotionEnabled()
        if isRightOpen {
            _ = ensureRightDrawerPanel()
            if animate { animateRightDrawer(opening: true) } else { relayoutPanels() }
            focusDrawer(.right)
        } else {
            if animate { animateRightDrawer(opening: false) } else { relayoutPanels() }
            // See `toggleBottomDrawer`: restore focus only if this drawer held it.
            if focusedPanel == .rightDrawer { restoreFocusAfterClosingDrawer(otherOpen: isBottomOpen, other: .bottom) }
        }
    }

    private func ensureRightDrawerPanel() -> PanelHostView {
        if let existing = rightDrawerPanel { return existing }
        let surface = makeSurface()
        surface.delegate = self
        let token = registerDrawerToken(.rightDrawer)
        rightDrawerToken = token
        // A workspace recipe runs a program here (e.g. claude) that drops back to a shell;
        // a plain toggle-open right drawer is just a shell.
        surface.start(drawerConfig(command: rightDrawerCommand, token: token))
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
    /// lazygit tracks the pane, never a stale directory). Overlays zoom without exiting
    /// it — closing the float leaves the panel underneath still zoomed.
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
        if lazygitSurface != nil, lazygitAnchor(for: focusedCWD)?.path != lazygitLaunchAnchor?.path {
            discardLazygitSurface()  // focused pane moved repos → respawn at the current cwd
        }
        showLazygit(ensureLazygitSurface())
    }

    /// Schedule the background pre-warm after `prewarmDelay` (ZEN-55): the delay keeps
    /// the lazygit login shell out of `applyRecipe`'s spawn turn (which already opens the
    /// main pane and up to two drawers), so a workspace open doesn't burst four shells.
    private func schedulePrewarmLazygit() {
        prewarmWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.prewarmWorkItem = nil
            self?.prewarmLazygitNow()
        }
        prewarmWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + prewarmDelay, execute: item)
    }

    /// Spawn the lazygit surface in the background (no overlay shown) so the first `⌘G`
    /// reveals an already-loaded lazygit, and admit it to the background LRU cap. Only
    /// for stable-path tabs inside a repo — a plain tab's cwd drifts, and lazygit is
    /// useless off-repo. The surface-exists guard runs first, so a `⌘G` that beat the
    /// timer (already live and promoted) is never re-admitted and made evictable. Also
    /// the visible-quit rewarm path — a used surface re-enters the cap. Internal for
    /// deterministic tests.
    func prewarmLazygitNow() {
        guard lazygitSurface == nil else { return }
        guard hasStablePath, gitRepoRoot(for: focusedCWD) != nil else { return }
        _ = ensureLazygitSurface()
        prewarmPool.admit(self) { [weak self] in self?.discardLazygitSurface() }
    }

    /// A repo/workspace tab (opened via `⌘⇧P`, so `pinnedTitle` is set) has a fixed
    /// repo path worth keeping lazygit warm for. A plain `⌘t` tab does not.
    private var hasStablePath: Bool { pinnedTitle != nil }

    /// The enclosing git repo root for `cwd` — walks up looking for `GitRepo.isGitRepo` — or
    /// nil when `cwd` isn't inside a repo.
    private func gitRepoRoot(for cwd: URL?) -> URL? {
        guard var dir = cwd?.standardizedFileURL else { return nil }
        while true {
            if GitRepo.isGitRepo(dir) { return dir }
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
        let shell = ShellLaunch.userShell
        let surface = makeSurface()
        surface.delegate = self
        // `-l -i`: a login AND interactive shell, so it sources BOTH profile files and
        // `.zshrc` — matching how lazygit runs when typed in a pane. Without `-i`, a
        // login-only shell skips `.zshrc`, so env it sets (e.g. XDG_CONFIG_HOME →
        // lazygit's config path, COLORTERM) is missing and lazygit renders different colors.
        surface.start(
            TerminalSurfaceConfig(
                command: shell, args: ["-l", "-i", "-c", "lazygit"],
                workingDirectory: focusedCWD, theme: Theme.current.terminal,
                behavior: GeneralConfig.current.terminalBehavior))
        lazygitSurface = surface
        lazygitLaunchAnchor = lazygitAnchor(for: focusedCWD)
        return surface
    }

    /// Terminate and drop the persisted surface. The ref is cleared BEFORE `terminate()`
    /// so a synchronous exit re-entry into `surfaceDidExit` is a no-op. Next reveal
    /// recreates it at the then-current cwd.
    private func discardLazygitSurface() {
        // No-ops when this discard IS a pool eviction — the pool drops the entry
        // before running the evict closure.
        prewarmPool.remove(self)
        let surface = lazygitSurface
        lazygitSurface = nil
        lazygitLaunchAnchor = nil
        surface?.terminate()
    }

    /// Reveal the persisted surface: mount its overlay above the tab's tile and give
    /// it the tab's unified focus.
    private func showLazygit(_ surface: TerminalSurface) {
        // The user opened `⌘G`: promote the surface out of the never-opened pool — an
        // actually-used lazygit is never evicted — and drop any pending pre-warm.
        prewarmWorkItem?.cancel()
        prewarmWorkItem = nil
        prewarmPool.remove(self)
        // A prior overlay springing out still constrains `surface.view`; snap it away now so
        // reparenting into the new card doesn't leave the old card's constraints dangling.
        lazygitDismissingOverlay?.removeFromSuperview()
        lazygitDismissingOverlay = nil
        let overlay = LazygitOverlay(
            content: surface.view,
            background: Theme.current.chrome.background.nsColor,
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
        guard let guardSpec = spec.emptyGuard else {
            showToolFloat(spec)
            return
        }
        // Decide off the main thread: a `git diff`-style probe on a large repo or cold disk would
        // otherwise beachball on the keybind press. The float animates in either way, so a
        // sub-100ms deferred decision is invisible.
        guard probingToolFloatID == nil else { return }  // a probe is already deciding — ignore re-press
        probingToolFloatID = spec.id
        probeIsEmpty(guardSpec.probe) { [weak self] isEmpty in
            guard let self else { return }
            self.probingToolFloatID = nil
            guard self.activeToolFloat == nil else { return }  // a float opened while we probed
            if isEmpty {
                self.onRequestToast?(guardSpec.toast)
            } else {
                self.showToolFloat(spec)
            }
        }
    }

    /// Spawn `spec.command` in a fresh login+interactive shell at the focused cwd (so
    /// the user's git pager / PATH match a pane), present it in a `SurfaceFloatOverlay`,
    /// and give it the tab's unified focus. When the command exits, `surfaceDidExit`
    /// tears the float down.
    private func showToolFloat(_ spec: ToolFloat) {
        let shell = ShellLaunch.userShell
        let surface = makeSurface()
        surface.delegate = self
        surface.start(
            TerminalSurfaceConfig(
                command: shell, args: ["-l", "-i", "-c", spec.command],
                workingDirectory: focusedCWD, theme: Theme.current.terminal,
                behavior: GeneralConfig.current.terminalBehavior))
        let overlay = SurfaceFloatOverlay(
            content: surface.view,
            background: Theme.current.chrome.background.nsColor,
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

    /// The empty-guard probe's watchdog timeout — a pathological probe is terminated after this so
    /// it can't run forever. On timeout (or any error) we fail open (show the float).
    private static let probeTimeout: TimeInterval = 2

    /// Run `probe` as a plain (non-login) shell at the focused cwd; exit 0 ⇒ nothing to show.
    /// Used by a float's `emptyGuard` to toast instead of opening an empty float. Runs entirely on
    /// a background queue — the main thread is never blocked — and calls `completion` on the main
    /// queue. Bounded by a `probeTimeout` watchdog and fail-open (isEmpty == false) on any
    /// error/timeout so it never wrongly guards.
    private func probeIsEmpty(_ probe: String, completion: @escaping (Bool) -> Void) {
        let shell = ShellLaunch.userShell
        let cwd = focusedCWD ?? ShellLaunch.defaultCWD
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: shell)
            process.arguments = ["-c", probe]
            process.currentDirectoryURL = cwd
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                DispatchQueue.main.async { completion(false) }  // couldn't probe → open the float
                return
            }
            // Reap on a separate worker and wait on it with a timeout, so a probe that ignores
            // SIGTERM can NEVER wedge the decision: on timeout we fail open immediately (isEmpty
            // == false) and best-effort terminate, while the reaper keeps waiting to collect the
            // child. `completion` fires exactly once, so `probingToolFloatID` is always cleared.
            let finished = DispatchSemaphore(value: 0)
            DispatchQueue.global(qos: .userInitiated).async {
                process.waitUntilExit()
                finished.signal()
            }
            let isEmpty: Bool
            if finished.wait(timeout: .now() + Self.probeTimeout) == .timedOut {
                process.terminate()
                isEmpty = false
            } else {
                isEmpty = process.terminationStatus == 0
            }
            DispatchQueue.main.async { completion(isEmpty) }
        }
    }

    // MARK: tiling

    private func makeDrawerPanel(edge: DrawerEdge, surface: TerminalSurface) -> PanelHostView {
        // A labeled header (title + live toggle keybind) instead of a floating corner icon;
        // the drawer is toggled from the footer dock or the keymap (ZEN-65).
        let meta =
            edge == .bottom
            ? PanelMeta(title: "Bottom drawer", action: .toggleBottomDrawer)
            : PanelMeta(title: "Right drawer", action: .toggleRightDrawer)
        let panel = PanelHostView(
            content: surface.view,
            background: Theme.current.chrome.background.nsColor,
            meta: meta,
            onFocusRequest: { [weak self] in self?.focusDrawer(edge) })
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
        syncDrawerFocus()
        surface?.focus()
        onFocusChanged?()  // a drawer click also steals focus from a confirm — void it
    }

    /// Push each drawer surface's cursor-focus to match `focusedPanel` — the explicit
    /// counterpart to `PaneCanvasController.updateHalo`, so a drawer never keeps a blinking
    /// cursor once focus moves off it.
    private func syncDrawerFocus() {
        bottomDrawerSurface?.setFocused(focusedPanel == .bottomDrawer)
        rightDrawerSurface?.setFocused(focusedPanel == .rightDrawer)
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
        syncDrawerFocus()
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

    /// Jump a drawer zoom from one edge to the other (⌘B/⌘\ while the *other* drawer is
    /// zoomed) — full-screen the target instead of exiting zoom. Opens the target if it
    /// wasn't already; the drawer we jump from stays open (just hidden under the new zoom),
    /// so exiting zoom later tiles both.
    private func switchZoomedDrawer(to edge: DrawerEdge) {
        switch edge {
        case .bottom:
            isBottomOpen = true
            _ = ensureBottomDrawerPanel()
            rightDrawerPanel?.isZoomed = false
            bottomDrawerPanel?.isZoomed = true
            zoomedPanel = .bottomDrawer
        case .right:
            isRightOpen = true
            _ = ensureRightDrawerPanel()
            bottomDrawerPanel?.isZoomed = false
            rightDrawerPanel?.isZoomed = true
            zoomedPanel = .rightDrawer
        }
        relayoutPanels()
        focusDrawer(edge)
    }

    /// Unzoom if zoomed; returns true if it did. (Shared with PR3's Escape handling.)
    @discardableResult func exitZoomIfNeeded() -> Bool {
        if isZoomed { exitZoom(); return true }
        return false
    }

    /// The last "disabled while zoomed" toast (verb + when) — held ⌘-chords auto-repeat, so
    /// coalesce repeats of the SAME verb into one card; a distinct blocked command always
    /// speaks, so nothing is ever a silent no-op.
    private var lastZoomBlockToast: (verb: String, at: Date)?
    private static let zoomBlockToastThrottle: TimeInterval = 3

    /// The last "nothing in that direction" nav toast (direction + when) — same auto-repeat
    /// coalescing as the zoom toast, keyed by direction so a distinct dead direction still speaks.
    private var lastNoNeighborToast: (direction: Direction, at: Date)?

    /// A grid command (split / navigate / resize / drawers) was invoked while zoomed. Zoom is
    /// a strict focus mode, so instead of silently doing nothing, point the user at ⌘F.
    private func toastZoomBlocked(_ verb: String) {
        let now = Date()
        if let last = lastZoomBlockToast, last.verb == verb,
            now.timeIntervalSince(last.at) < Self.zoomBlockToastThrottle
        {
            return
        }
        lastZoomBlockToast = (verb, now)
        onRequestToast?(
            ToastContent(
                variant: .info, title: "Zoom mode",
                message: "Exit zoom (⌘F) to \(verb)."))
    }

    /// A ⌘hjkl nav found no panel in `direction` — the edge of the layout, or only a diagonal
    /// that isn't a straight neighbor. Speak it instead of a silent no-op; held chords auto-repeat,
    /// so coalesce repeats of the SAME direction into one card while a distinct dead direction
    /// always speaks.
    private func toastNoNeighbor(_ direction: Direction) {
        let now = Date()
        if let last = lastNoNeighborToast, last.direction == direction,
            now.timeIntervalSince(last.at) < Self.zoomBlockToastThrottle
        {
            return
        }
        lastNoNeighborToast = (direction, now)
        let action: KeyInterceptor.ReservedChord
        let word: String
        switch direction {
        case .left: action = .navLeft; word = "left"
        case .right: action = .navRight; word = "right"
        case .up: action = .navUp; word = "up"
        case .down: action = .navDown; word = "down"
        }
        // Title is the command itself ("Focus Pane Left"), from the same catalog the palette
        // uses so it tracks any rename; the message says what's missing.
        onRequestToast?(
            ToastContent(
                variant: .info,
                title: CommandCatalog.spec(for: action).title,
                message: "No pane \(word) to focus"))
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
        if isZoomed { toastZoomBlocked("navigate"); return }
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
        guard let target else {
            toastNoNeighbor(direction)  // no silent no-op — every dead nav attempt speaks
            return
        }

        navReturn[target, default: [:]][direction.opposite] = origin  // enable the return hop
        focusPanel(target)
    }

    /// Drop focus-memory entries for panes that have closed, so `navReturn` doesn't grow with
    /// every pane ever created in a long-lived tab. Correctness already tolerates stale entries
    /// (they fail the still-open / in-direction checks in `navigate`) — this is memory hygiene only.
    private func pruneNavReturn(closed: [PaneID]) {
        navReturn = Self.navReturnPruned(navReturn, removing: Set(closed))
    }

    /// Pure transform behind `pruneNavReturn`, factored out so it's unit-testable without a live
    /// pane canvas: drops each closed pane both as an origin key and as a remembered target, and
    /// drops any origin left with no directions.
    static func navReturnPruned(
        _ map: [PaneID: [Direction: PaneID]], removing closed: Set<PaneID>
    ) -> [PaneID: [Direction: PaneID]] {
        var result: [PaneID: [Direction: PaneID]] = [:]
        for (origin, inner) in map where !closed.contains(origin) {
            let kept = inner.filter { !closed.contains($0.value) }
            if !kept.isEmpty { result[origin] = kept }
        }
        return result
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

    /// Whether `candidate` lies in `direction` from `origin` — PaneKit's `lies`, which
    /// also requires perpendicular-axis overlap. Center offset alone let the full-height
    /// right drawer pass as "up" from the bottom drawer (it's diagonal), so a ⌃J hop out
    /// of it poisoned the return memory and ⌃K from the bottom drawer skipped the canvas
    /// for the rest of the session.
    private func isPanel(
        _ candidate: PaneID, inDirection direction: Direction,
        from origin: PaneID, frames: [PaneID: CGRect]
    ) -> Bool {
        lies(candidate, inDirection: direction, from: origin, frames: frames)
    }

    /// Resize whichever panel holds focus by moving its edge in `direction`. For a pane
    /// this defers to the pane canvas's edge-aware resize. A docked drawer only resizes
    /// along its own axis, growing toward the canvas: the bottom drawer grows up (⌘⇧K) and
    /// shrinks down (⌘⇧J); the right drawer grows left into the canvas (⌘⇧H) and shrinks
    /// right (⌘⇧L) — the same feel as an edge pane on that side. The cross axis beeps. A
    /// resize chord while zoomed just unzooms, matching `navigate`.
    func resize(_ direction: Direction) {
        if isZoomed { toastZoomBlocked("resize"); return }
        switch focusedPanel {
        case .pane:
            paneCanvas.resize(direction)
        case .bottomDrawer:
            let axis = content.bounds.height
            switch direction {
            case .up: bottomDrawerRatio = nudgedDrawerRatio(bottomDrawerRatio, by: Self.drawerResizeStep, along: axis)
            case .down:
                bottomDrawerRatio = nudgedDrawerRatio(bottomDrawerRatio, by: -Self.drawerResizeStep, along: axis)
            case .left, .right: NSSound.beep(); return
            }
            relayoutPanels()
        case .rightDrawer:
            let axis = content.bounds.width
            switch direction {
            case .left: rightDrawerRatio = nudgedDrawerRatio(rightDrawerRatio, by: Self.drawerResizeStep, along: axis)
            case .right: rightDrawerRatio = nudgedDrawerRatio(rightDrawerRatio, by: -Self.drawerResizeStep, along: axis)
            case .up, .down: NSSound.beep(); return
            }
            relayoutPanels()
        }
    }

    /// Nudge a drawer's fraction by a pixel step (so ⌥-arrows keep their fixed feel), clamped
    /// to `[minDrawerExtent, maxDrawerFraction · axis]` in pixels and converted back to a
    /// fraction. Returns the fraction unchanged if the axis hasn't been laid out yet.
    private func nudgedDrawerRatio(_ ratio: CGFloat, by deltaPixels: CGFloat, along axis: CGFloat) -> CGFloat {
        guard axis > 0 else { return ratio }
        let ceiling = max(Self.minDrawerExtent, axis * Self.maxDrawerFraction)
        let extent = min(max(ratio * axis + deltaPixels, Self.minDrawerExtent), ceiling)
        return extent / axis
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

    /// Re-apply the live chrome-layout knobs (window gutter, pane gap) to this built tab after a
    /// config change — no relaunch. `relayoutPanels()` re-reads `panelGap`; the gutter constraints
    /// get their new constant. Drawer fractions are intentionally not reset (a hand ⌥-resize owns
    /// the running ratio; the new fraction seeds new tabs).
    func reapplyChromeLayout() {
        let gutter = ChromeMetrics.windowGutter
        // Sign is keyed to positional identity, not the live constant: at gutter == 0 the
        // trailing/bottom constraints were built with `-0.0`, and `-0.0 < 0` is false in Swift,
        // so inferring sign from the current value silently flips them positive on the next
        // reapply. Order is fixed at construction above: 0 leading, 1 trailing, 2 top, 3 bottom.
        for (index, constraint) in gutterConstraints.enumerated() {
            constraint.constant = (index == 1 || index == 3) ? -gutter : gutter
        }
        relayoutPanels()
        view.layoutSubtreeIfNeeded()
    }

    /// Re-apply the live pane border / focus-halo colors to this built tab after a config
    /// change — no relaunch. Sibling to `reapplyChromeLayout()` (layout only); covers the pane
    /// canvas plus any built drawer panels.
    func reapplyChromeColors() {
        paneCanvas.reapplyChromeColors()
        bottomDrawerPanel?.reapplyTheme()
        rightDrawerPanel?.reapplyTheme()
        lazygitOverlay?.reapplyTheme()
        activeToolFloat?.overlay.reapplyTheme()
    }

    /// Begin clipping `content` for a drawer slide (a drawer parks just outside the content bounds
    /// before sliding in). Ref-counted so overlapping slides share one clip.
    private func beginDrawerSlideClip() {
        activeDrawerSlides += 1
        content.wantsLayer = true
        content.layer?.masksToBounds = true
    }

    /// Balance `beginDrawerSlideClip`; lift the clip once the last in-flight slide finishes.
    private func endDrawerSlideClip() {
        activeDrawerSlides = max(0, activeDrawerSlides - 1)
        if activeDrawerSlides == 0 { content.layer?.masksToBounds = false }
    }

    /// Animate the bottom drawer open/closed with a fluid push. The canvas is a *real* resize —
    /// panes genuinely compress upward — but the drawer *slides* in at its final size rather than
    /// growing from zero, so its own terminal reflows once (settling its prompt) and then stays put
    /// instead of jittering through every row count. The two stay one `panelGap` apart the whole
    /// way: the canvas bottom rises by `slide` while the drawer translates up by `slide` on the same
    /// curve. The drawer is parked below the content's bottom edge at the start, so `content` is
    /// clipped for the duration to keep it from spilling over the footer. On completion it settles
    /// onto the canonical multiplier constraints via `relayoutPanels()` (same size, no jump),
    /// preserving window-resize proportionality. Zoom / Reduce Motion use the instant path.
    /// (Spike: bottom drawer only — the right drawer still swaps instantly.)
    private func animateBottomDrawer(opening: Bool) {
        guard let bottomPanel = bottomDrawerPanel else {
            relayoutPanels()
            return
        }
        content.layoutSubtreeIfNeeded()
        let target = max(0, content.bounds.height * bottomDrawerRatio)
        let slide = target + ChromeMetrics.panelGap  // canvas-bottom rise == drawer travel

        // Final-position constraints: the drawer fills the bottom band at full size (so its terminal
        // reflows once, now, and holds), while the canvas is tied to the content bottom through an
        // animatable inset we drive from full → pushed-up.
        NSLayoutConstraint.deactivate(tileConstraints)
        setAttached(bottomPanel, true)
        let canvasBottomC = canvas.bottomAnchor.constraint(
            equalTo: content.bottomAnchor, constant: opening ? 0 : -slide)
        var cs: [NSLayoutConstraint] = [
            canvas.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            canvas.topAnchor.constraint(equalTo: content.topAnchor),
            canvasBottomC,
            bottomPanel.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bottomPanel.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            bottomPanel.heightAnchor.constraint(equalToConstant: target),
        ]
        // Mirror `relayoutPanels`' column split: an open right drawer bounds both the canvas and the
        // bottom drawer's trailing edge, so the push stays inside the canvas column.
        if isRightOpen, let rightPanel = rightDrawerPanel {
            let width = rightPanel.widthAnchor.constraint(
                equalTo: content.widthAnchor, multiplier: rightDrawerRatio)
            width.priority = .defaultHigh
            cs += [
                rightPanel.topAnchor.constraint(equalTo: content.topAnchor),
                rightPanel.bottomAnchor.constraint(equalTo: content.bottomAnchor),
                rightPanel.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                width,
                canvas.trailingAnchor.constraint(equalTo: rightPanel.leadingAnchor, constant: -ChromeMetrics.panelGap),
                bottomPanel.trailingAnchor.constraint(
                    equalTo: rightPanel.leadingAnchor, constant: -ChromeMetrics.panelGap),
            ]
        } else {
            cs += [
                canvas.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                bottomPanel.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            ]
        }
        NSLayoutConstraint.activate(cs)
        tileConstraints = cs
        content.layoutSubtreeIfNeeded()  // drawer + canvas now sit at their final frames

        // The drawer parks below the content's bottom edge before sliding up, so clip the overflow.
        beginDrawerSlideClip()

        let landing = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)  // the tab page-slide's landing
        bottomDrawerAnimationID &+= 1
        let animationID = bottomDrawerAnimationID

        // Drawer: slide its final-size layer (no reflow). Canvas: real-resize its constraint.
        bottomPanel.wantsLayer = true
        let restTranslation: CGFloat = opening ? 0 : -slide
        bottomPanel.layer?.transform = CATransform3DMakeTranslation(0, restTranslation, 0)  // model at rest
        let slideAnim = CABasicAnimation(keyPath: "transform.translation.y")
        slideAnim.fromValue = opening ? -slide : 0
        slideAnim.toValue = restTranslation
        slideAnim.duration = Motion.pageSlideDuration
        slideAnim.timingFunction = landing

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Motion.pageSlideDuration
            ctx.timingFunction = landing
            canvasBottomC.animator().constant = opening ? -slide : 0
            bottomPanel.layer?.add(slideAnim, forKey: "drawer.slide")
        } completionHandler: { [weak self] in
            guard let self else { return }
            self.endDrawerSlideClip()
            // A newer toggle already owns the layout — leave it be (but the clip was still balanced).
            guard self.bottomDrawerAnimationID == animationID else { return }
            bottomPanel.layer?.transform = CATransform3DIdentity
            if !opening { self.setAttached(bottomPanel, false) }
            self.relayoutPanels()  // settle onto the canonical multiplier constraints
        }
    }

    /// The right-drawer twin of `animateBottomDrawer`, rotated to the horizontal axis: the drawer
    /// slides in from the right edge at its final width (one reflow, then held) while the canvas
    /// real-resizes leftward. When the bottom drawer is open its trailing edge rides left on the
    /// same curve, so the right drawer visibly pushes it. Settles onto the canonical constraints on
    /// completion. (Spike: the bottom drawer's width-follow is a real resize — it reflows.)
    private func animateRightDrawer(opening: Bool) {
        guard let rightPanel = rightDrawerPanel else {
            relayoutPanels()
            return
        }
        content.layoutSubtreeIfNeeded()
        let target = max(0, content.bounds.width * rightDrawerRatio)
        let slide = target + ChromeMetrics.panelGap  // canvas-trailing shift == drawer travel

        NSLayoutConstraint.deactivate(tileConstraints)
        setAttached(rightPanel, true)
        let canvasTrailingC = canvas.trailingAnchor.constraint(
            equalTo: content.trailingAnchor, constant: opening ? 0 : -slide)
        var cs: [NSLayoutConstraint] = [
            canvas.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            canvas.topAnchor.constraint(equalTo: content.topAnchor),
            canvasTrailingC,
            rightPanel.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            rightPanel.topAnchor.constraint(equalTo: content.topAnchor),
            rightPanel.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            rightPanel.widthAnchor.constraint(equalToConstant: target),
        ]
        // With the bottom drawer open, its column is the canvas column: tie its bottom edge and
        // animate its trailing left in lockstep with the canvas, so the right drawer pushes it too.
        var bottomTrailingC: NSLayoutConstraint?
        if isBottomOpen, let bottomPanel = bottomDrawerPanel {
            let height = bottomPanel.heightAnchor.constraint(
                equalTo: content.heightAnchor, multiplier: bottomDrawerRatio)
            height.priority = .defaultHigh
            let trailing = bottomPanel.trailingAnchor.constraint(
                equalTo: content.trailingAnchor, constant: opening ? 0 : -slide)
            bottomTrailingC = trailing
            cs += [
                bottomPanel.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                bottomPanel.bottomAnchor.constraint(equalTo: content.bottomAnchor),
                height,
                trailing,
                canvas.bottomAnchor.constraint(equalTo: bottomPanel.topAnchor, constant: -ChromeMetrics.panelGap),
            ]
        } else {
            cs.append(canvas.bottomAnchor.constraint(equalTo: content.bottomAnchor))
        }
        NSLayoutConstraint.activate(cs)
        tileConstraints = cs
        content.layoutSubtreeIfNeeded()  // drawer + canvas now sit at their final frames

        // The drawer parks past the content's right edge before sliding in, so clip the overflow.
        beginDrawerSlideClip()

        let landing = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)  // the tab page-slide's landing
        rightDrawerAnimationID &+= 1
        let animationID = rightDrawerAnimationID

        rightPanel.wantsLayer = true
        let restTranslation: CGFloat = opening ? 0 : slide
        rightPanel.layer?.transform = CATransform3DMakeTranslation(restTranslation, 0, 0)  // model at rest
        let slideAnim = CABasicAnimation(keyPath: "transform.translation.x")
        slideAnim.fromValue = opening ? slide : 0
        slideAnim.toValue = restTranslation
        slideAnim.duration = Motion.pageSlideDuration
        slideAnim.timingFunction = landing

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Motion.pageSlideDuration
            ctx.timingFunction = landing
            canvasTrailingC.animator().constant = opening ? -slide : 0
            bottomTrailingC?.animator().constant = opening ? -slide : 0
            rightPanel.layer?.add(slideAnim, forKey: "drawer.slide")
        } completionHandler: { [weak self] in
            guard let self else { return }
            self.endDrawerSlideClip()
            guard self.rightDrawerAnimationID == animationID else { return }
            rightPanel.layer?.transform = CATransform3DIdentity
            if !opening { self.setAttached(rightPanel, false) }
            self.relayoutPanels()  // settle onto the canonical multiplier constraints
        }
    }

    private func relayoutPanels() {
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
            let width = rightPanel.widthAnchor.constraint(
                equalTo: content.widthAnchor, multiplier: rightDrawerRatio)
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
            let height = bottomPanel.heightAnchor.constraint(
                equalTo: content.heightAnchor, multiplier: bottomDrawerRatio)
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
    /// A drawer surface posted a desktop notification (the workspace `claude` drawer) — relay
    /// it as the tab's attention signal, same as a pane.
    func surface(_ s: TerminalSurface, didPostNotification n: TerminalNotification) {
        onNotification?(n)
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
                // Re-warm only after a VISIBLE quit: an instantly-exiting surface (lazygit
                // not on PATH, or a drifted non-repo cwd) exits while hidden, so it can never
                // spin a respawn loop. The rewarm re-enters the background LRU cap — a used
                // surface is a warm background surface again, not exempt (ZEN-55). Plain tabs
                // (no stable path) respawn on the next ⌘G.
                prewarmLazygitNow()
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
            unregisterDrawerToken(.bottomDrawer)
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
            unregisterDrawerToken(.rightDrawer)
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
