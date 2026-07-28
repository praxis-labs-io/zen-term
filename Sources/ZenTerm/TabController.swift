import AppKit
import PaneKit
import TerminalKit

/// Which edge a drawer panel docks to.
enum DrawerEdge { case bottom, right }

/// Which panel is filling the tab (zoomed), for the footer dock's zoom tint.
enum ZoomedPanel: Equatable { case pane, bottomDrawer, rightDrawer }

/// A tab's overlay open-state (drawers + zoom), produced by `TabController` and mirrored by the
/// footer toggle dock's active tints. Tool floats are window-level (ZEN-141), so the shown float
/// isn't part of a tab's state — the dock takes it from `ToolFloatController` instead.
struct OverlayState: Equatable {
    var isBottomOpen = false
    var isRightOpen = false
    var zoomed: ZoomedPanel?
    /// Whether each drawer's shell has a live process — drives the footer dock's activity dot
    /// when the drawer is hidden (ZEN-107).
    var bottomBusy = false
    var rightBusy = false
}

/// One tab: owns the pane tree (`PaneCanvasController`) and the per-tab overlay
/// surfaces (drawers, tool floats) and zoom. `view` is the tab's container that
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

    /// Whether the window's modal tool float is covering this tab (ZEN-141 lifted the float
    /// engine to `WindowController`, so the tab has to ask). Drives the guards that must not act
    /// on a panel hidden behind a modal card.
    private let isToolFloatOpen: () -> Bool

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
    /// the auxiliary drawer surfaces. Used to re-theme all surfaces live on a config change.
    /// Tool floats belong to the window, not the tab — `ToolFloatController.allSurfaces` covers
    /// them in the same fan-out.
    var allSurfaces: [TerminalSurface] {
        paneCanvas.allSurfaces + [bottomDrawerSurface, rightDrawerSurface].compactMap { $0 }
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

    /// Whether a drawer (not the pane canvas) holds the tab's focus — so ⌘W targets that
    /// drawer instead of bubbling up to the pane/tab close (ZEN-213).
    var isDrawerFocused: Bool { focusedPanel != .pane }

    /// Whether the focused drawer has a running process. False when the pane holds focus, so
    /// the ⌘W drawer path can confirm on a busy drawer and close an idle one silently.
    var focusedDrawerIsBusy: Bool { focusedDrawerSurface?.isBusy == true }

    /// The tab's overlay open-state (drawers + zoom), for the footer dock's active tints; fired
    /// via `onOverlayStateChanged` whenever one of them toggles. The shown tool float isn't in
    /// here — it belongs to the window, and the dock reads it from there.
    var overlayState: OverlayState {
        OverlayState(
            isBottomOpen: isBottomOpen, isRightOpen: isRightOpen,
            zoomed: zoomedPanel.map(\.asZoomed),
            bottomBusy: bottomDrawerSurface?.isBusy == true,
            rightBusy: rightDrawerSurface?.isBusy == true)
    }
    var onOverlayStateChanged: (() -> Void)?

    /// Request a transient top-right toast (e.g. `⌘G` blocked outside a git repo).
    var onRequestToast: ((ToastContent) -> Void)?

    /// A pane's surface failed to start — relayed from the pane canvas. Carries the
    /// retry/close actions so the `WindowController` (which owns the toast presenter) can
    /// show an actionable sticky notice.
    var onPaneStartFailed: ((@escaping () -> Void, @escaping () -> Void) -> Void)?

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
        isToolFloatOpen: @escaping () -> Bool = { false },
        makeSurface: @escaping () -> TerminalSurface = TerminalSurfaceFactory.make
    ) {
        workspaceEnv = env
        self.isToolFloatOpen = isToolFloatOpen
        self.makeSurface = makeSurface
        paneCanvas = PaneCanvasController(
            initialCWD: initialCWD, initialCommand: initialCommand, env: env,
            makeSurface: makeSurface)
        canvas = paneCanvas.canvasView
        canvas.translatesAutoresizingMaskIntoConstraints = false
        super.init()

        content.translatesAutoresizingMaskIntoConstraints = false
        // Layer-back the tile container so the floats added into it later (⌘P picker, tool floats)
        // composite their drop shadows — a layer-backed view dropped into a non-layer-backed
        // parent after layout doesn't render its shadow.
        content.wantsLayer = true
        view.addSubview(content)
        // Content-rect inset: `windowGutter` on leading/trailing/bottom; the top adds traffic-light
        // clearance when window chrome is shown (`ChromeMetrics.topInset`), else matches the others.
        gutterConstraints = [
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: ChromeMetrics.windowGutter),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -ChromeMetrics.windowGutter),
            content.topAnchor.constraint(equalTo: view.topAnchor, constant: ChromeMetrics.topInset),
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
        paneCanvas.onSurfaceStartFailed = { [weak self] retry, close in self?.onPaneStartFailed?(retry, close) }
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

    /// Close the focused drawer entirely — the same teardown as typing `exit` in it (ZEN-213).
    /// No-op when a pane holds focus; the pane/tab close path handles that case.
    func closeFocusedDrawer() {
        switch focusedPanel {
        case .pane: return
        case .bottomDrawer: closeDrawer(.bottom)
        case .rightDrawer: closeDrawer(.right)
        }
    }
    func focusActivePane() { paneCanvas.focusActivePane() }

    /// Apply a workspace's open recipe: reveal only the drawers the recipe names (each running
    /// its configured command, via `rightDrawerCommand`/`bottomDrawerCommand` set before this)
    /// and land focus on the requested region. Called once right after `start()` for a
    /// workspace-opened tab. A recipe naming no drawers leaves a single pane with both drawers
    /// collapsed — the minimal default.
    func applyRecipe(_ ws: Workspace) {
        if ws.right != nil, !isRightOpen { toggleRightDrawer() }
        if ws.bottom != nil, !isBottomOpen { toggleBottomDrawer() }
        switch ws.focus {
        case .right where isRightOpen: focusDrawer(.right)
        case .bottom where isBottomOpen: focusDrawer(.bottom)
        default: focusActivePane()  // main, or a named drawer the recipe didn't open
        }
    }

    /// Present a modal overlay filling the tab's tile region — same scoping as the
    /// tool floats (pinned to `content`, above the canvas and any drawers). Used by
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

    /// Drop the tab's unified focus (halo + first responder) — the window's modal float is taking
    /// it. `focusedPanel` is deliberately left alone, so closing the card restores focus to
    /// whichever panel had it.
    func yieldFocusToFloat() {
        paneCanvas.setPanesFocused(false)
        bottomDrawerPanel?.isFocused = false
        rightDrawerPanel?.isFocused = false
    }

    func shutdown() {
        paneCanvas.shutdown()
        bottomDrawerSurface?.terminate()
        bottomDrawerSurface = nil
        unregisterDrawerToken(.bottomDrawer)
        rightDrawerSurface?.terminate()
        rightDrawerSurface = nil
        unregisterDrawerToken(.rightDrawer)
    }

    /// Copy from whichever panel holds unified focus: the pane canvas's own copy
    /// path, or — for a focused drawer — its surface's selection straight to the
    /// pasteboard (mirrors `PaneCanvasController.copyFromSurface`).
    @objc func copyFromSurface(_ sender: Any?) {
        guard let surface = focusedDrawerSurface else {
            paneCanvas.copyFromSurface(sender)
            return
        }
        guard let text = surface.copySelection(), !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: send a diff comment (ZEN-257)

    /// The terminals in this tab a diff comment can be sent to, **the focused one first** — the
    /// composer defaults to index 0, so a comment with no target picked lands where you were working.
    ///
    /// Panes come in the tree's own order so their numbers read left to right; a drawer is listed only
    /// while it's open, because pasting into a hidden one puts text somewhere you can't see it.
    func sendTargets() -> [DiffSendTarget] {
        var targets: [DiffSendTarget] = []
        for (index, id) in paneCanvas.orderedLeafIDs.enumerated() {
            targets.append(
                DiffSendTarget(
                    id: id, label: Self.targetLabel("pane \(index + 1)", surface: paneCanvas.surface(for: id))))
        }
        if isBottomOpen, let surface = bottomDrawerSurface {
            targets.append(
                DiffSendTarget(id: Self.bottomDrawerID, label: Self.targetLabel("bottom drawer", surface: surface)))
        }
        if isRightOpen, let surface = rightDrawerSurface {
            targets.append(
                DiffSendTarget(id: Self.rightDrawerID, label: Self.targetLabel("right drawer", surface: surface)))
        }
        let focused = currentPanelID
        return targets.filter { $0.id == focused } + targets.filter { $0.id != focused }
    }

    /// The place plus what's running there ("pane 2 · claude"), so two shells in the same tab are
    /// tellable apart. The place always leads: a terminal with no title is still `pane 2`.
    private static func targetLabel(_ place: String, surface: TerminalSurface?) -> String {
        guard let title = surface?.title, !title.isEmpty else { return place }
        return "\(place) · \(title)"
    }

    /// Deliver a composed diff comment to `target`.
    ///
    /// `submit` focuses the target, pastes, and presses Return (`submitLine`, a real keypress — not a
    /// pasted `"\r"`, which lands inside the bracketed-paste block where a TUI reads it as a literal
    /// newline and never sends).
    ///
    /// `queue` pastes the message plus a trailing newline **without** focusing or submitting, so
    /// several comments can stack in the target's input (each on its own line) and the reviewer stays
    /// in the diff to add more before a final submit fires them together.
    func send(_ message: String, to target: DiffSendTarget, action: DiffSendAction) {
        guard let surface = surface(for: target.id) else { return }
        switch action {
        case .submit:
            focusPanel(target.id)
            surface.paste(message)
            surface.submitLine()
        case .queue:
            surface.paste(message + "\n")
        }
    }

    /// The surface behind a panel id in the shared nav id space — a drawer sentinel or a pane leaf.
    private func surface(for id: PaneID) -> TerminalSurface? {
        if id == Self.bottomDrawerID { return bottomDrawerSurface }
        if id == Self.rightDrawerID { return rightDrawerSurface }
        return paneCanvas.surface(for: id)
    }

    /// Paste into whichever panel holds unified focus (mirrors
    /// `PaneCanvasController.pasteToSurface` for the drawer case).
    @objc func pasteToSurface(_ sender: Any?) {
        guard let surface = focusedDrawerSurface else {
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

    /// Restore the tab's unified focus — halo and keyboard first-responder — to whichever panel
    /// holds `focusedPanel`. Called when the tab is (re)mounted, and by the window when its modal
    /// float closes (the float takes focus via `yieldFocusToFloat` without touching
    /// `focusedPanel`, so the panel that had it gets it back). Honoring `focusedPanel` is what
    /// keeps a tab that was focused on a drawer from wrongly landing on the central pane.
    func restoreUnifiedFocus() {
        switch focusedPanel {
        case .pane: paneCanvas.focusActivePane()
        case .bottomDrawer: focusDrawer(.bottom)
        case .rightDrawer: focusDrawer(.right)
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
        // While zoomed the header title reads "<drawer>: Focus Mode" and the toggle keybind is
        // replaced by ⌘F, matching the pane's Focus Mode header.
        let zoomMeta =
            edge == .bottom
            ? PanelMeta(title: "Bottom drawer: Focus Mode", action: .toggleZoom)
            : PanelMeta(title: "Right drawer: Focus Mode", action: .toggleZoom)
        let panel = PanelHostView(
            content: surface.view,
            meta: meta, zoomMeta: zoomMeta,
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
        guard !isToolFloatOpen() else { return }  // can't zoom a panel under the float
        if isZoomed { exitZoom(); return }
        // Every case relayouts to the final size FIRST, then pops the now-full panel — a pop before
        // the resize would scale at the old (tiled) size and then snap to full. A pane's pop lives
        // inside `PaneCanvasController`; a drawer's is `popZoom` here.
        switch focusedPanel {
        case .pane:
            // Nothing to isolate: a lone pane with no open drawer. Focusing would hide nothing, so
            // block it rather than enter a dead Focus Mode. Focusing a drawer always hides the
            // canvas, so drawer cases are always meaningful and never blocked.
            guard !isSinglePane || isBottomOpen || isRightOpen else { toastFocusModeUnavailable(); return }
            zoomedPanel = .pane
            relayoutPanels()
            view.layoutSubtreeIfNeeded()  // canvas at full size before the pane pops
            // A drawer being open means the canvas was tiled, so zooming even a lone pane really resizes it.
            paneCanvas.zoomFocusedLeaf(resizesCanvas: isBottomOpen || isRightOpen)
        case .bottomDrawer:
            guard isBottomOpen, let panel = bottomDrawerPanel else { return }
            panel.isZoomed = true
            zoomedPanel = .bottomDrawer
            relayoutPanels()
            popZoom(panel, growing: true)
        case .rightDrawer:
            guard isRightOpen, let panel = rightDrawerPanel else { return }
            panel.isZoomed = true
            zoomedPanel = .rightDrawer
            relayoutPanels()
            popZoom(panel, growing: true)
        }
    }

    private func exitZoom() {
        // Symmetry with `toggleZoom`: tile back to the final size first, then pop the panel there.
        // Only the drawer that was full-screen pops back into its dock; the canvas panes just reappear.
        switch zoomedPanel {
        case .pane:
            zoomedPanel = nil
            relayoutPanels()
            view.layoutSubtreeIfNeeded()  // canvas back to its tiled size before the pane pops
            paneCanvas.unzoom(resizesCanvas: isBottomOpen || isRightOpen)
        case .bottomDrawer:
            bottomDrawerPanel?.isZoomed = false
            rightDrawerPanel?.isZoomed = false
            zoomedPanel = nil
            relayoutPanels()
            if let panel = bottomDrawerPanel { popZoom(panel, growing: false) }
        case .rightDrawer:
            bottomDrawerPanel?.isZoomed = false
            rightDrawerPanel?.isZoomed = false
            zoomedPanel = nil
            relayoutPanels()
            if let panel = rightDrawerPanel { popZoom(panel, growing: false) }
        case nil: return
        }
    }

    /// Scale-pop a view for the full-screen (zoom) transition, kept in sync with the pane zoom via
    /// `Motion.zoomPop`. `growing` is the zoom direction (in vs out). Honors Reduce Motion.
    private func popZoom(_ view: NSView, growing: Bool) {
        view.superview?.layoutSubtreeIfNeeded()  // ensure the view has its final frame before scaling about its center
        Motion.zoomPop(view, growing: growing)
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

    /// The last "nothing to focus" toast — ⌘F on a lone pane with no open drawer auto-repeats too.
    private var lastFocusUnavailableToast: Date?

    /// The last "nothing in that direction" nav toast (direction + when) — same auto-repeat
    /// coalescing as the zoom toast, keyed by direction so a distinct dead direction still speaks.
    private var lastNoNeighborToast: (direction: Direction, at: Date)?

    /// A grid command (split / navigate / resize / drawers) was invoked while zoomed. Focus Mode is
    /// strict, so instead of silently doing nothing, point the user at ⌘F.
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
                variant: .info, title: "Focus Mode",
                message: "Exit Focus Mode (⌘F) to \(verb)."))
    }

    /// ⌘F on a lone pane with no open drawer: focusing would hide nothing, so there's nothing to
    /// isolate. Say why rather than entering a Focus Mode that changes nothing on screen.
    private func toastFocusModeUnavailable() {
        let now = Date()
        if let last = lastFocusUnavailableToast, now.timeIntervalSince(last) < Self.zoomBlockToastThrottle {
            return
        }
        lastFocusUnavailableToast = now
        onRequestToast?(
            ToastContent(
                variant: .info, title: "Focus Mode",
                message: "Focus Mode needs a second pane or an open drawer."))
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
        // Sign and value are keyed to positional identity, not the live constant: at gutter == 0 the
        // trailing/bottom constraints were built with `-0.0`, and `-0.0 < 0` is false in Swift,
        // so inferring sign from the current value silently flips them positive on the next
        // reapply. Order is fixed at construction above: 0 leading, 1 trailing, 2 top, 3 bottom.
        // The top (index 2) carries the traffic-light clearance, so it tracks `topInset`, not `gutter`.
        for (index, constraint) in gutterConstraints.enumerated() {
            switch index {
            case 1, 3: constraint.constant = -gutter
            case 2: constraint.constant = ChromeMetrics.topInset
            default: constraint.constant = gutter
            }
        }
        // The canvas↔drawer seams get their gap from the constraints `relayoutPanels()` rebuilds
        // below, but a split bakes its gutter in at construction — so the pane canvas needs telling.
        paneCanvas.reapplyChromeLayout()
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
    }

    /// Begin a drawer slide: clip `content` (a drawer parks just outside the content bounds before
    /// sliding in) and freeze every grid for the duration, so the canvas reflows once at its final
    /// size instead of once per animation frame. Ref-counted so overlapping slides share both.
    private func beginDrawerSlide() {
        activeDrawerSlides += 1
        if activeDrawerSlides == 1 { allSurfaces.forEach { $0.setSizeSyncSuspended(true) } }
        SlideClip.apply(to: content)
    }

    /// Balance `beginDrawerSlide`; lift the clip and let the grids reconcile to their landed frames
    /// once the last in-flight slide finishes.
    private func endDrawerSlide() {
        activeDrawerSlides = max(0, activeDrawerSlides - 1)
        if activeDrawerSlides == 0 {
            SlideClip.remove(from: content)
            allSurfaces.forEach { $0.setSizeSyncSuspended(false) }
        }
    }

    /// Shared drawer-slide machinery for both edges: clip `content`, park `panel` off-edge at its
    /// final size and slide it in on the landing curve while `animate` (the canvas — and, when the
    /// right drawer opens over an open bottom drawer, that drawer's trailing) real-resize to their
    /// targets. On completion the last in-flight slide settles the canonical constraints; a closing
    /// panel is detached before its transform resets so it can't flash. `isCurrent` reports whether a
    /// newer toggle of *this* edge has superseded the slide. The caller has already installed the
    /// final-position constraints and bumped this edge's animation id.
    private func runDrawerSlide(
        panel: PanelHostView, opening: Bool, parkOffset: CGVector,
        animate: [(constraint: NSLayoutConstraint, to: CGFloat)], isCurrent: @escaping () -> Bool
    ) {
        // The one reflow, now, at the geometry the slide lands on: run the animated constraints to
        // their targets and lay out, then freeze the grids and rewind to the starting frame. For
        // the length of the slide the canvas's terminals hold their final grid while their views
        // animate around them, which the layer's `contentsGravity` already covers (ZEN-282).
        let slideStarts = animate.map(\.constraint.constant)
        for (constraint, target) in animate { constraint.constant = target }
        content.layoutSubtreeIfNeeded()
        beginDrawerSlide()
        for (pair, start) in zip(animate, slideStarts) { pair.constraint.constant = start }
        content.layoutSubtreeIfNeeded()

        let parked = CATransform3DMakeTranslation(parkOffset.dx, parkOffset.dy, 0)
        let restT = opening ? CATransform3DIdentity : parked  // a closed drawer ends parked off-screen
        panel.wantsLayer = true
        panel.layer?.transform = restT  // model at rest
        let slideAnim = CABasicAnimation(keyPath: "transform")
        slideAnim.fromValue = NSValue(caTransform3D: opening ? parked : CATransform3DIdentity)
        slideAnim.toValue = NSValue(caTransform3D: restT)
        slideAnim.duration = Motion.pageSlideDuration
        slideAnim.timingFunction = Motion.landingTiming

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Motion.pageSlideDuration
            ctx.timingFunction = Motion.landingTiming
            for (constraint, target) in animate { constraint.animator().constant = target }
            panel.layer?.add(slideAnim, forKey: "drawer.slide")
        } completionHandler: { [weak self] in
            guard let self else { return }
            // `activeDrawerSlides` still counts this slide (balanced last, below): 1 means it's the
            // only one, so it's safe to settle the shared tile constraints; >1 means a sibling drawer
            // is mid-slide and its own completion will do the final relayout — relaying out now would
            // tear down its in-flight animation.
            let isLastSlide = self.activeDrawerSlides <= 1
            if isCurrent() {  // else a newer toggle of this edge owns the layout
                if !opening { self.setAttached(panel, false) }  // detach while parked + clipped — no flash
                panel.layer?.transform = CATransform3DIdentity
                if isLastSlide { self.relayoutPanels() }  // settle onto the canonical multiplier constraints
            }
            self.endDrawerSlide()  // balance last, so the clip outlives the detach
        }
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
    /// `animateRightDrawer` is the horizontal twin.
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
        // `.defaultHigh` (like `relayoutPanels`) so an extremely short window relaxes the drawer
        // instead of forcing the canvas negative and logging a broken constraint.
        let drawerHeight = bottomPanel.heightAnchor.constraint(equalToConstant: target)
        drawerHeight.priority = .defaultHigh
        var cs: [NSLayoutConstraint] = [
            canvas.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            canvas.topAnchor.constraint(equalTo: content.topAnchor),
            canvasBottomC,
            bottomPanel.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bottomPanel.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            drawerHeight,
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

        // Drawer slides up (parks below); canvas bottom rises by `slide` in lockstep.
        bottomDrawerAnimationID &+= 1
        let id = bottomDrawerAnimationID
        runDrawerSlide(
            panel: bottomPanel, opening: opening, parkOffset: CGVector(dx: 0, dy: -slide),
            animate: [(canvasBottomC, opening ? -slide : 0)],
            isCurrent: { [weak self] in self?.bottomDrawerAnimationID == id })
    }

    /// The right-drawer twin of `animateBottomDrawer`, rotated to the horizontal axis: the drawer
    /// slides in from the right edge at its final width (one reflow, then held) while the canvas
    /// real-resizes leftward. When the bottom drawer is open its trailing edge rides left on the
    /// same curve, so the right drawer visibly pushes it. Settles onto the canonical constraints on
    /// completion. (The bottom drawer's width-follow is a real resize — it reflows.)
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
        // `.defaultHigh` (like `relayoutPanels`) so a very narrow window relaxes the drawer instead
        // of forcing the canvas negative and logging a broken constraint.
        let drawerWidth = rightPanel.widthAnchor.constraint(equalToConstant: target)
        drawerWidth.priority = .defaultHigh
        var cs: [NSLayoutConstraint] = [
            canvas.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            canvas.topAnchor.constraint(equalTo: content.topAnchor),
            canvasTrailingC,
            rightPanel.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            rightPanel.topAnchor.constraint(equalTo: content.topAnchor),
            rightPanel.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            drawerWidth,
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

        // Drawer slides in from the right (parks past the right edge); canvas — and the open bottom
        // drawer's trailing — shift left by `slide` in lockstep, so the right drawer pushes both.
        rightDrawerAnimationID &+= 1
        let id = rightDrawerAnimationID
        var animate: [(constraint: NSLayoutConstraint, to: CGFloat)] = [(canvasTrailingC, opening ? -slide : 0)]
        if let bottomTrailingC { animate.append((bottomTrailingC, opening ? -slide : 0)) }
        runDrawerSlide(
            panel: rightPanel, opening: opening, parkOffset: CGVector(dx: slide, dy: 0),
            animate: animate, isCurrent: { [weak self] in self?.rightDrawerAnimationID == id })
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
    /// focus. A tool float is modal and already holds focus, so it's ignored.
    func surfaceWantsFocus(_ s: TerminalSurface) {
        if s === bottomDrawerSurface { focusDrawer(.bottom) } else if s === rightDrawerSurface { focusDrawer(.right) }
    }
    /// A drawer surface posted a desktop notification (the workspace `claude` drawer) — relay
    /// it as the tab's attention signal, same as a pane.
    func surface(_ s: TerminalSurface, didPostNotification n: TerminalNotification) {
        onNotification?(n)
    }
    /// A program repainted a drawer's background (OSC 11). Carry it to that drawer's own fill,
    /// exactly as a pane does (ZEN-23). Panes are handled in `PaneCanvasController` and floats in
    /// `ToolFloatController`; this only reacts to the two drawer surfaces.
    ///
    /// No pull to go with it, for the same reason a pane needs none: a drawer's surface and its
    /// panel are created together and cleared together, so the panel never postdates the surface.
    func surface(_ s: TerminalSurface, backgroundDidChange color: TerminalColor) {
        if s === bottomDrawerSurface {
            bottomDrawerPanel?.backgroundOverride = color
        } else if s === rightDrawerSurface {
            rightDrawerPanel?.backgroundOverride = color
        }
    }
    /// A drawer's shell exited on its own (e.g. the user typed `exit`): close+clear
    /// that drawer entirely — rather than leaving a dead shell docked — so the next
    /// toggle lazily spawns a fresh one. Panes have their own exit handling in
    /// `PaneCanvasController`; this only reacts to the two drawer surfaces.
    func surfaceDidExit(_ s: TerminalSurface, code: Int32?) {
        if s === bottomDrawerSurface {
            closeDrawer(.bottom)
        } else if s === rightDrawerSurface {
            closeDrawer(.right)
        }
    }

    /// Tear a drawer down entirely: drop its panel view, terminate the surface, clear its
    /// refs + nav token, mark it closed, re-tile, and restore focus if it held it. This is
    /// the shell-is-gone path — shared by `surfaceDidExit` (the user typed `exit`) and ⌘W on
    /// a focused drawer (ZEN-213), which is meant to behave exactly like `exit`. Distinct from
    /// `toggle*Drawer()`, which merely hides a drawer and keeps its shell alive.
    private func closeDrawer(_ edge: DrawerEdge) {
        let ref: PanelRef
        switch edge {
        case .bottom:
            ref = .bottomDrawer
            if zoomedPanel == .bottomDrawer { zoomedPanel = nil }  // don't leave zoom stuck
            bottomDrawerPanel?.removeFromSuperview()
            bottomDrawerSurface?.terminate()
            bottomDrawerSurface = nil
            bottomDrawerPanel = nil
            unregisterDrawerToken(.bottomDrawer)
            isBottomOpen = false
        case .right:
            ref = .rightDrawer
            if zoomedPanel == .rightDrawer { zoomedPanel = nil }  // don't leave zoom stuck
            rightDrawerPanel?.removeFromSuperview()
            rightDrawerSurface?.terminate()
            rightDrawerSurface = nil
            rightDrawerPanel = nil
            unregisterDrawerToken(.rightDrawer)
            isRightOpen = false
        }
        relayoutPanels()
        // `focusActivePane()` restores BOTH the pane's keyboard first-responder and — via
        // `onFocusChanged` → `paneGainedFocus()` — the unified halo/routing state, so
        // closing a focused drawer doesn't orphan keystrokes until the next click. But NOT
        // while the modal float is open: it must keep focus, so only re-point `focusedPanel`
        // to the pane (the now-gone drawer) so closing the float later restores focus right.
        if focusedPanel == ref {
            if isToolFloatOpen() { focusedPanel = .pane } else { paneCanvas.focusActivePane() }
        }
    }

    /// A drawer surface failed to start. Surface a passive warning and tear it down so the next
    /// toggle spawns a fresh one — the natural retry for a drawer, unlike panes, which get an
    /// in-place Retry button. Panes are handled entirely in `PaneCanvasController` and floats in
    /// `ToolFloatController`; this only reacts to the surfaces this controller owns.
    func surfaceDidFailToStart(_ s: TerminalSurface) {
        // A drawer only exists after an explicit open, so always warn, then reuse
        // `surfaceDidExit`'s teardown (clear ref, drop the view, terminate, relayout, restore
        // focus) so the next toggle spawns a fresh surface.
        let descriptor: String
        if s === bottomDrawerSurface {
            descriptor = "The bottom drawer"
        } else if s === rightDrawerSurface {
            descriptor = "The right drawer"
        } else {
            return  // not one of ours
        }
        warnSurfaceFailed(descriptor: descriptor)
        surfaceDidExit(s, code: nil)
    }

    private func warnSurfaceFailed(descriptor: String) {
        onRequestToast?(
            ToastContent(
                variant: .warning, title: "Terminal Didn't Start",
                message: "\(descriptor) failed to launch. Open it again to retry."))
    }
}
