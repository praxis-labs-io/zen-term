import AppKit

/// Hosts the web view on a `stage` sized to the device width and visually scaled to
/// the pane. The scale comes from the AppKit trick of giving `stage` a bounds larger
/// than its frame: the web view lays out at `contentWidth` (so responsive CSS reflows
/// at that width) and is rendered scaled down into the pane — letterboxed when it
/// fits, clipped when a percent overflows. Relayouts on pane resize, device, or zoom.
public final class WebStageHost: NSView {
    /// The view sized to the device width; the web view fills it and is scaled with it.
    public let stage = NSView()

    public var contentWidth: CGFloat = 1280 { didSet { needsLayout = true } }
    public var zoom: WebZoom = .fit { didSet { needsLayout = true } }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        stage.wantsLayer = true
        addSubview(stage)
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    public override func layout() {
        super.layout()
        let paneW = bounds.width
        let paneH = bounds.height
        guard paneW > 0, paneH > 0 else { return }

        let scale = max(0.05, zoom.scale(paneWidth: paneW, contentWidth: contentWidth))
        let frameW = (contentWidth * scale).rounded()
        // frame is the on-screen rect; bounds is the (larger) layout space — the
        // frame/bounds ratio is the scale AppKit applies to everything inside `stage`.
        stage.frame = NSRect(x: ((paneW - frameW) / 2).rounded(), y: 0, width: frameW, height: paneH)
        stage.bounds = NSRect(x: 0, y: 0, width: contentWidth, height: (paneH / scale).rounded())
        stage.layoutSubtreeIfNeeded()
    }
}
