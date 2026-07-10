import AppKit

/// The per-leaf host view the pane canvas manages: it shows the unified focus halo,
/// participates in zoom, and contributes its frame to spatial nav. A terminal leaf
/// uses `PanelHostView` (bordered card + iris halo); a web leaf uses `WebPaneHostView`
/// (transparent, with a bordered toolbar as its focus target). Keeping the canvas's
/// focus/zoom/frame logic uniform across both is the whole reason for this seam.
protocol PaneHost: NSView {
    var isFocused: Bool { get set }
    var isZoomed: Bool { get set }
    var onZoomExit: (() -> Void)? { get set }
}

extension PanelHostView: PaneHost {}
