import AppKit
import PaneKit
import TerminalKit

/// Which edge a drawer panel docks to.
enum DrawerEdge { case bottom, right }

/// A tab's overlay open-state (drawers + lazygit), produced by `TabController` and
/// mirrored by the footer toggle dock's active tints.
struct OverlayState: Equatable {
    var isBottomOpen = false
    var isRightOpen = false
    var isLazygitOpen = false
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
    private let canvas: NSView            // paneCanvas.canvasView, cached

    private static let bottomDrawerHeight: CGFloat = 300
    private static let rightDrawerWidth: CGFloat = 480   // roomy enough for a Claude chat panel

    // Per-tab auxiliary surfaces (created lazily; kept alive when hidden — the shell
    // persists across toggles and is only terminated in `shutdown()`).
    private var bottomDrawerSurface: TerminalSurface?
    private var bottomDrawerPanel: PanelHostView?
    private var isBottomOpen = false { didSet { onOverlayStateChanged?() } }

    private var rightDrawerSurface: TerminalSurface?
    private var rightDrawerPanel: PanelHostView?
    private var isRightOpen = false { didSet { onOverlayStateChanged?() } }

    // The lazygit float: a transient top-most overlay (unlike drawers, its surface is
    // NOT persistent — it's terminated on every dismiss and re-spawned on the next ⌘G).
    private var lazygitSurface: TerminalSurface?
    private var lazygitOverlay: LazygitOverlay?
    var isLazygitOpen: Bool { lazygitOverlay != nil }

    /// Which panel currently holds the tab's single unified focus/halo.
    private enum PanelRef: Equatable { case pane, bottomDrawer, rightDrawer }
    private var focusedPanel: PanelRef = .pane

    /// The zoomed panel (fills the tab, others hidden), or nil when not zoomed.
    private var zoomedPanel: PanelRef?
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

    /// The tab's overlay open-state (drawers + lazygit), for the footer dock's active
    /// tints; fired via `onOverlayStateChanged` whenever one of them toggles.
    var overlayState: OverlayState {
        OverlayState(isBottomOpen: isBottomOpen, isRightOpen: isRightOpen, isLazygitOpen: isLazygitOpen)
    }
    var onOverlayStateChanged: (() -> Void)?

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
        view.addSubview(content)
        // Content-rect inset: `topInset` clears the window's traffic lights (the window
        // uses .fullSizeContentView); the sides/bottom use `windowGutter`.
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: ChromeMetrics.windowGutter),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -ChromeMetrics.windowGutter),
            content.topAnchor.constraint(equalTo: view.topAnchor, constant: ChromeMetrics.topInset),
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
        exitZoomIfNeeded()   // exit zoom before closing so zoom state can't desync
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
    /// the active pane. Without the float check, remounting (tab switch-back, new/close
    /// tab) steals focus to the pane hidden behind the still-visible float.
    func restoreKeyFocus() {
        if isLazygitOpen { lazygitSurface?.focus() } else { paneCanvas.focusActivePane() }
    }

    func shutdown() {
        paneCanvas.shutdown()
        bottomDrawerSurface?.terminate()
        bottomDrawerSurface = nil
        rightDrawerSurface?.terminate()
        rightDrawerSurface = nil
        lazygitSurface?.terminate()
        lazygitSurface = nil
    }

    /// Copy from whichever panel holds unified focus: the pane canvas's own copy
    /// path, or — for a focused drawer — its surface's selection straight to the
    /// pasteboard (mirrors `PaneCanvasController.copyFromSurface`).
    @objc func copyFromSurface(_ sender: Any?) {
        // While the modal float is open, copy targets it, not the panel underneath.
        guard let surface = lazygitSurface ?? focusedDrawerSurface else {
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
        guard let surface = lazygitSurface ?? focusedDrawerSurface else {
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
        exitZoomIfNeeded()   // any layout change exits zoom first (keeps state in sync)
        isBottomOpen.toggle()
        if isBottomOpen {
            _ = ensureBottomDrawerPanel()
            relayoutPanels()   // attaches + tiles it (visibility follows open state)
            focusDrawer(.bottom)
        } else {
            relayoutPanels()   // detaches it (surface stays alive)
            // Only steal focus back to the pane canvas if the drawer being hidden was
            // the one holding unified focus. `focusActivePane()` bubbles through
            // `paneCanvas.onFocusChanged` to reassert unified focus onto the canvas.
            if focusedPanel == .bottomDrawer { paneCanvas.focusActivePane() }
        }
    }

    private func ensureBottomDrawerPanel() -> PanelHostView {
        if let existing = bottomDrawerPanel { return existing }
        let surface = TerminalSurfaceFactory.make()
        surface.delegate = self
        surface.start(ShellLaunch.shell(cwd: focusedCWD))
        bottomDrawerSurface = surface
        let panel = makeDrawerPanel(edge: .bottom, surface: surface)
        bottomDrawerPanel = panel   // relayoutPanels() attaches it to `content`
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
            // See `toggleBottomDrawer`: only steal focus if this drawer held it.
            if focusedPanel == .rightDrawer { paneCanvas.focusActivePane() }
        }
    }

    private func ensureRightDrawerPanel() -> PanelHostView {
        if let existing = rightDrawerPanel { return existing }
        let surface = TerminalSurfaceFactory.make()
        surface.delegate = self
        // The workspace preset runs a program here (claude) that drops back to a shell;
        // a plain toggle-open right drawer is just a shell.
        surface.start(rightDrawerCommand.map { ShellLaunch.program($0, cwd: focusedCWD) }
                      ?? ShellLaunch.shell(cwd: focusedCWD))
        rightDrawerSurface = surface
        let panel = makeDrawerPanel(edge: .right, surface: surface)
        rightDrawerPanel = panel   // relayoutPanels() attaches it to `content`
        return panel
    }

    // MARK: lazygit float (⌘G)

    /// Toggle the lazygit float. Opening spawns a fresh surface running `lazygit` via
    /// a login shell (so a Homebrew `lazygit` is on PATH — Epic 0's login-shell fix) in
    /// the focused pane's cwd, and overlays it centered above everything. Mutually
    /// exclusive with zoom (opening exits any zoom first). It auto-closes when lazygit
    /// exits (`surfaceDidExit`); `⌘G` again, or a backdrop click, also dismiss it.
    func toggleLazygit() {
        if isLazygitOpen { closeLazygit(); return }
        exitZoomIfNeeded()   // zoom and the float are mutually exclusive
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let surface = TerminalSurfaceFactory.make()
        surface.delegate = self
        // `-l -i`: a login AND interactive shell, so it sources BOTH profile files and
        // `.zshrc` — matching how lazygit runs when typed in a pane. Without `-i`, a
        // login-only shell skips `.zshrc`, so env it sets (e.g. XDG_CONFIG_HOME →
        // lazygit's config path, COLORTERM) is missing and lazygit renders different colors.
        surface.start(TerminalSurfaceConfig(command: shell, args: ["-l", "-i", "-c", "lazygit"],
                                            workingDirectory: focusedCWD, theme: Theme.rosePineMoon))
        lazygitSurface = surface
        let overlay = LazygitOverlay(content: surface.view,
                                     background: Theme.rosePineMoon.background.nsColor,
                                     onDismiss: { [weak self] in self?.closeLazygit() })
        overlay.translatesAutoresizingMaskIntoConstraints = false
        // Mount in `content` (the tile region), not `view`: the modal covers only the
        // tab's working area — never the window gutters or the tab bar — and sits above
        // the canvas and any open drawers.
        content.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: content.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        lazygitOverlay = overlay
        // Focus reads only on the float: clear the underlying panels' halos (keep
        // `focusedPanel` so close can restore it).
        paneCanvas.setPanesFocused(false)
        bottomDrawerPanel?.isFocused = false
        rightDrawerPanel?.isFocused = false
        surface.focus()
        onOverlayStateChanged?()   // lazygit now open → refresh the dock
    }

    private func closeLazygit() {
        lazygitOverlay?.removeFromSuperview()
        lazygitOverlay = nil
        // Clear the ref BEFORE terminating: `terminate()` may synchronously re-enter
        // `surfaceDidExit`, and a nil `lazygitSurface` makes that re-entry a no-op.
        let surface = lazygitSurface
        lazygitSurface = nil
        surface?.terminate()
        restoreUnifiedFocus()   // the float held keyboard focus; hand it back to its panel
        onOverlayStateChanged?()   // lazygit now closed → refresh the dock
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

    // MARK: tiling

    private func makeDrawerPanel(edge: DrawerEdge, surface: TerminalSurface) -> PanelHostView {
        // Headers dropped for now — drawers use the bare pane chrome (meta: nil). A
        // corner hide button (chevron pointing the way it collapses) toggles the drawer.
        let hideGlyph = edge == .bottom ? "⌄" : "›"
        let panel = PanelHostView(content: surface.view,
                                  background: Theme.rosePineMoon.background.nsColor,
                                  meta: nil,
                                  hideButton: (glyph: hideGlyph, onHide: { [weak self] in
                                      switch edge {
                                      case .bottom: self?.toggleBottomDrawer()
                                      case .right: self?.toggleRightDrawer()
                                      }
                                  }),
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
    }

    /// The pane canvas (re)gained focus — reassert unified focus onto it: it holds
    /// the tab's single halo again and both drawer panels go unfocused.
    private func paneGainedFocus() {
        focusedPanel = .pane
        paneCanvas.setPanesFocused(true)
        bottomDrawerPanel?.isFocused = false
        rightDrawerPanel?.isFocused = false
    }

    // MARK: zoom (⌘F)

    /// Zoom the focused panel to fill the tab (others hidden), or unzoom if already
    /// zoomed. For a pane, the pane canvas also renders just the focused leaf.
    func toggleZoom() {
        guard !isLazygitOpen else { return }   // can't zoom a panel under the float
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

    /// Move the tab's unified focus to the nearest panel — pane or open drawer — in
    /// `direction`. Pane leaf frames and any open drawer's frame are scored together
    /// by PaneKit's `nearestLeaf`, the same geometric scorer pane-to-pane nav already
    /// uses, so a drawer is just another panel in the graph.
    func navigate(_ direction: Direction) {
        if exitZoomIfNeeded() { return }   // ⌘hjkl while zoomed just unzooms
        var frames = paneCanvas.leafFrames(in: content)
        if isBottomOpen, let panel = bottomDrawerPanel {
            frames[Self.bottomDrawerID] = flippedFrame(of: panel)
        }
        if isRightOpen, let panel = rightDrawerPanel {
            frames[Self.rightDrawerID] = flippedFrame(of: panel)
        }

        let origin: PaneID
        switch focusedPanel {
        case .pane: origin = paneCanvas.focusedLeafID
        case .bottomDrawer: origin = Self.bottomDrawerID
        case .rightDrawer: origin = Self.rightDrawerID
        }

        guard let target = nearestLeaf(from: origin, frames: frames, direction: direction) else { return }
        if target == Self.bottomDrawerID {
            focusDrawer(.bottom)
        } else if target == Self.rightDrawerID {
            focusDrawer(.right)
        } else {
            // `focusLeaf` bubbles through `paneCanvas.onFocusChanged` → `paneGainedFocus()`,
            // which reasserts unified focus (halo + panel routing) onto the pane canvas.
            paneCanvas.focusLeaf(target)
        }
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

    private func relayoutPanels() {
        NSLayoutConstraint.deactivate(tileConstraints)
        tileConstraints = []

        // The zoom target is only effective while its view exists (a zoomed drawer
        // whose shell just exited falls back to normal tiling).
        let effectiveZoom: PanelRef? = zoomedPanel.flatMap { zoomedView($0) != nil ? $0 : nil }

        let canvasVisible: Bool, bottomVisible: Bool, rightVisible: Bool
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
            let width = rightPanel.widthAnchor.constraint(equalToConstant: Self.rightDrawerWidth)
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
            let height = bottomPanel.heightAnchor.constraint(equalToConstant: Self.bottomDrawerHeight)
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
                cs.append(bottomPanel.trailingAnchor.constraint(equalTo: rightPanel.leadingAnchor, constant: -ChromeMetrics.panelGap))
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
    /// A drawer's shell exited on its own (e.g. the user typed `exit`): close+clear
    /// that drawer entirely — rather than leaving a dead shell docked — so the next
    /// toggle lazily spawns a fresh one. Panes have their own exit handling in
    /// `PaneCanvasController`; this only reacts to the two drawer surfaces.
    func surfaceDidExit(_ s: TerminalSurface, code: Int32?) {
        if s === lazygitSurface { closeLazygit(); return }   // lazygit quit (`q`) → auto-close
        if s === bottomDrawerSurface {
            if zoomedPanel == .bottomDrawer { zoomedPanel = nil }   // don't leave zoom stuck
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
            if zoomedPanel == .rightDrawer { zoomedPanel = nil }   // don't leave zoom stuck
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
