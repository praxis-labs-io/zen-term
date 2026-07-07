import AppKit
import PaneKit

/// One tab: owns the pane tree (`PaneCanvasController`) and — added in later tasks —
/// the per-tab overlay surfaces (drawers, lazygit) and zoom. `view` is the tab's
/// container that `WindowController` mounts; the pane canvas fills it, with drawers
/// docked to its edges in later tasks.
final class TabController: NSObject {
    let view = NSView()
    private let paneCanvas: PaneCanvasController

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
        super.init()
        let canvas = paneCanvas.canvasView
        canvas.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(canvas)
        NSLayoutConstraint.activate([
            canvas.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            canvas.topAnchor.constraint(equalTo: view.topAnchor),
            canvas.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    func start() { paneCanvas.start() }
    func split(_ axis: SplitAxis) { paneCanvas.split(axis) }
    func navigate(_ direction: Direction) { paneCanvas.navigate(direction) }
    @discardableResult func closeFocused() -> Bool { paneCanvas.closeFocused() }
    func focusActivePane() { paneCanvas.focusActivePane() }
    func shutdown() { paneCanvas.shutdown() }

    @objc func copyFromSurface(_ sender: Any?) { paneCanvas.copyFromSurface(sender) }
    @objc func pasteToSurface(_ sender: Any?) { paneCanvas.pasteToSurface(sender) }
}
