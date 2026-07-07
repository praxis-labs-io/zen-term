import AppKit
import PaneKit
import TerminalKit

/// Which edge a drawer panel docks to.
enum DrawerEdge { case bottom, right }

/// One tab: owns the pane tree (`PaneCanvasController`) and the per-tab overlay
/// surfaces (drawers, lazygit) and zoom. `view` is the tab's container that
/// `WindowController` mounts. `content` is the tab's tile region (inset from `view`
/// to clear the traffic lights and match the pane gutter); the pane canvas and any
/// open drawers tile within it as sibling panels — right drawer as a full-height
/// column, bottom drawer under the canvas in the remaining left column — separated
/// by the same 12pt gutter panes use, never overlapping.
final class TabController: NSObject {
    let view = NSView()
    private let content = NSView()
    private let paneCanvas: PaneCanvasController
    private let canvas: NSView            // paneCanvas.canvasView, cached

    private static let bottomDrawerHeight: CGFloat = 240
    private static let rightDrawerWidth: CGFloat = 360
    private static let gutter: CGFloat = 12

    // Per-tab auxiliary surfaces (created lazily; kept alive when hidden — the shell
    // persists across toggles and is only terminated in `shutdown()`).
    private var bottomDrawerSurface: TerminalSurface?
    private var bottomDrawerPanel: PanelHostView?
    private var isBottomOpen = false

    private var rightDrawerSurface: TerminalSurface?
    private var rightDrawerPanel: PanelHostView?
    private var isRightOpen = false

    /// Which panel currently holds the tab's single unified focus/halo.
    private enum PanelRef: Equatable { case pane, bottomDrawer, rightDrawer }
    private var focusedPanel: PanelRef = .pane

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

    var title: String { paneCanvas.title }
    var focusedCWD: URL? { paneCanvas.focusedCWD }

    init(initialCWD: URL?) {
        paneCanvas = PaneCanvasController(initialCWD: initialCWD)
        canvas = paneCanvas.canvasView
        canvas.translatesAutoresizingMaskIntoConstraints = false
        super.init()

        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content)
        // 12/12/36/12 content-rect inset: the 36pt top clears the window's traffic
        // lights (the window uses .fullSizeContentView); the 12pt sides/bottom match
        // the inter-panel gutter used below.
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Self.gutter),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Self.gutter),
            content.topAnchor.constraint(equalTo: view.topAnchor, constant: 36),
            content.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -Self.gutter),
        ])
        content.addSubview(canvas)
        relayoutPanels()

        paneCanvas.onFocusChanged = { [weak self] in self?.paneGainedFocus() }
    }

    func start() { paneCanvas.start() }
    func split(_ axis: SplitAxis) { paneCanvas.split(axis) }
    func navigate(_ direction: Direction) { paneCanvas.navigate(direction) }
    @discardableResult func closeFocused() -> Bool { paneCanvas.closeFocused() }
    func focusActivePane() { paneCanvas.focusActivePane() }

    func shutdown() {
        paneCanvas.shutdown()
        bottomDrawerSurface?.terminate()
        bottomDrawerSurface = nil
        rightDrawerSurface?.terminate()
        rightDrawerSurface = nil
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
        isBottomOpen.toggle()
        if isBottomOpen {
            let panel = ensureBottomDrawerPanel()
            panel.isHidden = false
            relayoutPanels()
            focusDrawer(.bottom)
        } else {
            bottomDrawerPanel?.isHidden = true
            relayoutPanels()
            // Only steal focus back to the pane canvas if the drawer being hidden was
            // the one holding unified focus — otherwise leave the currently focused
            // panel (e.g. the right drawer) alone. `focusActivePane()` bubbles through
            // `paneCanvas.onFocusChanged` to reassert unified focus onto the canvas.
            if focusedPanel == .bottomDrawer { paneCanvas.focusActivePane() }
        }
    }

    private func ensureBottomDrawerPanel() -> PanelHostView {
        if let existing = bottomDrawerPanel { return existing }
        let surface = TerminalSurfaceFactory.make()
        surface.delegate = self
        surface.start(TerminalSurfaceConfig(workingDirectory: focusedCWD, theme: Theme.rosePineMoon))
        bottomDrawerSurface = surface
        let panel = makeDrawerPanel(edge: .bottom, surface: surface)
        content.addSubview(panel)
        bottomDrawerPanel = panel
        return panel
    }

    // MARK: right drawer (⌘|)

    /// Toggle the right drawer. First open creates a persistent login-shell surface
    /// in the tab's cwd; toggling hidden keeps it running; it dies only in `shutdown()`.
    func toggleRightDrawer() {
        isRightOpen.toggle()
        if isRightOpen {
            let panel = ensureRightDrawerPanel()
            panel.isHidden = false
            relayoutPanels()
            focusDrawer(.right)
        } else {
            rightDrawerPanel?.isHidden = true
            relayoutPanels()
            // See `toggleBottomDrawer`: only steal focus if this drawer held it.
            if focusedPanel == .rightDrawer { paneCanvas.focusActivePane() }
        }
    }

    private func ensureRightDrawerPanel() -> PanelHostView {
        if let existing = rightDrawerPanel { return existing }
        let surface = TerminalSurfaceFactory.make()
        surface.delegate = self
        surface.start(TerminalSurfaceConfig(workingDirectory: focusedCWD, theme: Theme.rosePineMoon))
        rightDrawerSurface = surface
        let panel = makeDrawerPanel(edge: .right, surface: surface)
        content.addSubview(panel)
        rightDrawerPanel = panel
        return panel
    }

    // MARK: tiling

    private func makeDrawerPanel(edge: DrawerEdge, surface: TerminalSurface) -> PanelHostView {
        // Headers dropped for now — drawers use the bare pane chrome (meta: nil). The
        // PanelHostView meta capability stays available for when we bring them back.
        let panel = PanelHostView(content: surface.view,
                                  background: Theme.rosePineMoon.background.nsColor,
                                  meta: nil,
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

    /// Rebuild the tile layout from `isBottomOpen`/`isRightOpen`: the canvas + any
    /// open drawer panels as sibling panels within `content`, separated by a 12pt
    /// gutter, never overlapping. Right drawer is a full-height column; bottom
    /// drawer sits under the canvas in the remaining left column (never under the
    /// right column). Deactivates the previous tile constraint set before activating
    /// the new one so repeated toggles never accumulate constraints.
    private func relayoutPanels() {
        NSLayoutConstraint.deactivate(tileConstraints)

        var cs: [NSLayoutConstraint] = [
            canvas.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            canvas.topAnchor.constraint(equalTo: content.topAnchor),
        ]

        if isRightOpen, let rightPanel = rightDrawerPanel {
            cs += [
                rightPanel.topAnchor.constraint(equalTo: content.topAnchor),
                rightPanel.bottomAnchor.constraint(equalTo: content.bottomAnchor),
                rightPanel.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                rightPanel.widthAnchor.constraint(equalToConstant: Self.rightDrawerWidth),
                canvas.trailingAnchor.constraint(equalTo: rightPanel.leadingAnchor, constant: -Self.gutter),
            ]
        } else {
            cs.append(canvas.trailingAnchor.constraint(equalTo: content.trailingAnchor))
        }

        if isBottomOpen, let bottomPanel = bottomDrawerPanel {
            cs += [
                bottomPanel.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                bottomPanel.bottomAnchor.constraint(equalTo: content.bottomAnchor),
                bottomPanel.heightAnchor.constraint(equalToConstant: Self.bottomDrawerHeight),
                canvas.bottomAnchor.constraint(equalTo: bottomPanel.topAnchor, constant: -Self.gutter),
            ]
            // The bottom drawer spans the canvas column only — it stops short of the
            // right drawer's column, so the two never overlap when both are open.
            if isRightOpen, let rightPanel = rightDrawerPanel {
                cs.append(bottomPanel.trailingAnchor.constraint(equalTo: rightPanel.leadingAnchor, constant: -Self.gutter))
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
        if s === bottomDrawerSurface {
            bottomDrawerPanel?.removeFromSuperview()
            bottomDrawerSurface?.terminate()
            bottomDrawerSurface = nil
            bottomDrawerPanel = nil
            isBottomOpen = false
            relayoutPanels()
            if focusedPanel == .bottomDrawer { paneGainedFocus() }
        } else if s === rightDrawerSurface {
            rightDrawerPanel?.removeFromSuperview()
            rightDrawerSurface?.terminate()
            rightDrawerSurface = nil
            rightDrawerPanel = nil
            isRightOpen = false
            relayoutPanels()
            if focusedPanel == .rightDrawer { paneGainedFocus() }
        }
    }
}
