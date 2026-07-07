import AppKit
import PaneKit
import TerminalKit

/// One tab: owns the pane tree (`PaneCanvasController`) and — added in later tasks —
/// the per-tab overlay surfaces (drawers, lazygit) and zoom. `view` is the tab's
/// container that `WindowController` mounts; the pane canvas fills it, with drawers
/// docked to its edges.
final class TabController: NSObject {
    let view = NSView()
    private let paneCanvas: PaneCanvasController

    private let canvas: NSView            // paneCanvas.canvasView, cached
    private var canvasBottom: NSLayoutConstraint
    private var canvasTrailing: NSLayoutConstraint

    // Per-tab auxiliary surfaces (created lazily; kept alive when hidden — the shell
    // persists across toggles and is only terminated in `shutdown()`).
    private var bottomDrawerSurface: TerminalSurface?
    private var bottomDrawerView: DrawerView?
    private var isBottomOpen = false

    private var rightDrawerSurface: TerminalSurface?
    private var rightDrawerView: DrawerView?
    private var isRightOpen = false

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
        canvasBottom = canvas.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        canvasTrailing = canvas.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        super.init()
        view.addSubview(canvas)
        NSLayoutConstraint.activate([
            canvas.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            canvas.topAnchor.constraint(equalTo: view.topAnchor),
            canvasBottom,
            canvasTrailing,
        ])
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

    @objc func copyFromSurface(_ sender: Any?) { paneCanvas.copyFromSurface(sender) }
    @objc func pasteToSurface(_ sender: Any?) { paneCanvas.pasteToSurface(sender) }

    // MARK: bottom drawer (⌘B)

    /// Toggle the bottom drawer. First open creates a persistent login-shell surface
    /// in the tab's cwd; toggling hidden keeps it running; it dies only in `shutdown()`.
    func toggleBottomDrawer() {
        if isBottomOpen {
            isBottomOpen = false
            bottomDrawerView?.isHidden = true
            repointCanvasBottom(to: view.bottomAnchor)
            paneCanvas.focusActivePane()
            return
        }
        isBottomOpen = true
        let drawerView = ensureBottomDrawerView()
        drawerView.isHidden = false
        repointCanvasBottom(to: drawerView.topAnchor)
        bottomDrawerSurface?.focus()
    }

    /// The one place the canvas's bottom constraint changes target: deactivate the
    /// current constraint and activate a freshly built one pinned to `anchor`, so
    /// exactly one canvas-bottom constraint is ever active — no accumulation across
    /// repeated toggles.
    private func repointCanvasBottom(to anchor: NSLayoutYAxisAnchor) {
        canvasBottom.isActive = false
        canvasBottom = canvas.bottomAnchor.constraint(equalTo: anchor)
        canvasBottom.isActive = true
    }

    private func ensureBottomDrawerView() -> DrawerView {
        if let existing = bottomDrawerView { return existing }
        let surface = TerminalSurfaceFactory.make()
        surface.start(TerminalSurfaceConfig(workingDirectory: focusedCWD, theme: Theme.rosePineMoon))
        bottomDrawerSurface = surface
        let dv = DrawerView(edge: .bottom, content: surface.view,
                            background: Theme.rosePineMoon.background.nsColor)
        view.addSubview(dv)
        NSLayoutConstraint.activate([
            dv.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            dv.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            dv.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        bottomDrawerView = dv
        return dv
    }

    // MARK: right drawer (⌘|)

    /// Toggle the right drawer. First open creates a persistent login-shell surface
    /// in the tab's cwd; toggling hidden keeps it running; it dies only in `shutdown()`.
    func toggleRightDrawer() {
        if isRightOpen {
            isRightOpen = false
            rightDrawerView?.isHidden = true
            repointCanvasTrailing(to: view.trailingAnchor)
            paneCanvas.focusActivePane()
            return
        }
        isRightOpen = true
        let drawerView = ensureRightDrawerView()
        drawerView.isHidden = false
        repointCanvasTrailing(to: drawerView.leadingAnchor)
        rightDrawerSurface?.focus()
    }

    /// The one place the canvas's trailing constraint changes target: deactivate the
    /// current constraint and activate a freshly built one pinned to `anchor`, so
    /// exactly one canvas-trailing constraint is ever active — no accumulation across
    /// repeated toggles.
    private func repointCanvasTrailing(to anchor: NSLayoutXAxisAnchor) {
        canvasTrailing.isActive = false
        canvasTrailing = canvas.trailingAnchor.constraint(equalTo: anchor)
        canvasTrailing.isActive = true
    }

    private func ensureRightDrawerView() -> DrawerView {
        if let existing = rightDrawerView { return existing }
        let surface = TerminalSurfaceFactory.make()
        surface.start(TerminalSurfaceConfig(workingDirectory: focusedCWD, theme: Theme.rosePineMoon))
        rightDrawerSurface = surface
        let dv = DrawerView(edge: .right, content: surface.view,
                            background: Theme.rosePineMoon.background.nsColor)
        view.addSubview(dv)
        NSLayoutConstraint.activate([
            dv.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            dv.topAnchor.constraint(equalTo: view.topAnchor),
            dv.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        rightDrawerView = dv
        return dv
    }
}
