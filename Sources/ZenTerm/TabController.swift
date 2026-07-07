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

    // Per-tab auxiliary surfaces (created lazily; kept alive when hidden — the shell
    // persists across toggles and is only terminated in `shutdown()`).
    private var bottomDrawerSurface: TerminalSurface?
    private var bottomDrawerView: DrawerView?
    private var isBottomOpen = false

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
        super.init()
        view.addSubview(canvas)
        NSLayoutConstraint.activate([
            canvas.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            canvas.topAnchor.constraint(equalTo: view.topAnchor),
            canvasBottom,
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
}
