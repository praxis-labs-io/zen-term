import AppKit

final class FadingScrollView: NSScrollView {
    let fadeDepth: CGFloat

    private let axis: EdgeFade.Axis
    private let fade: EdgeFade
    private var isObserving = false

    // A full-size-content window pads a scrollable view by the titlebar height, which reads as a gap above the content.
    init(axis: EdgeFade.Axis = .vertical) {
        self.axis = axis
        fade = EdgeFade(axis: axis)
        fadeDepth = axis == .vertical ? 16 : 28
        super.init(frame: .zero)
        automaticallyAdjustsContentInsets = false
        contentInsets = .init()
    }

    convenience init(document: NSView) {
        self.init(axis: .vertical)
        drawsBackground = false
        hasVerticalScroller = true
        verticalScroller = SlimScroller()
        scrollerStyle = .overlay
        autohidesScrollers = true
        documentView = document
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // One fade depth of margin, or a view scrolled to an edge lands under the fade.
    func reveal(_ view: NSView) {
        let margin = view.bounds.insetBy(
            dx: axis == .horizontal ? -fadeDepth : 0, dy: axis == .vertical ? -fadeDepth : 0)
        view.scrollToVisible(margin)
    }

    override func layout() {
        super.layout()
        startObserving()
        refreshFade()
    }

    private func startObserving() {
        guard !isObserving, documentView != nil else { return }
        isObserving = true
        wantsLayer = true
        layer?.mask = fade.layer
        contentView.postsBoundsChangedNotifications = true
        documentView?.postsFrameChangedNotifications = true
        let center = NotificationCenter.default
        center.addObserver(
            self, selector: #selector(refreshFade), name: NSView.boundsDidChangeNotification, object: contentView)
        center.addObserver(
            self, selector: #selector(refreshFade), name: NSView.frameDidChangeNotification, object: documentView)
    }

    @objc private func refreshFade() {
        let (start, end) = axis == .vertical ? verticalOverflow() : horizontalOverflow()
        let length = axis == .vertical ? bounds.height : bounds.width
        let depth = length > 2 * fadeDepth ? fadeDepth : 0
        fade.update(frame: bounds, start: start ? depth : 0, end: end ? depth : 0)
    }

    private func horizontalOverflow() -> (start: Bool, end: Bool) {
        let visible = documentVisibleRect
        let width = documentView?.frame.width ?? 0
        return (visible.minX > 0.5, width - visible.maxX > 0.5)
    }

    private func verticalOverflow() -> (start: Bool, end: Bool) {
        let visible = documentVisibleRect
        let height = documentView?.frame.height ?? 0
        let nearOrigin = visible.minY > 0.5
        let nearEnd = height - visible.maxY > 0.5
        let hidesAbove = contentView.isFlipped ? nearOrigin : nearEnd
        let hidesBelow = contentView.isFlipped ? nearEnd : nearOrigin
        let startIsTop = layer?.contentsAreFlipped() ?? false
        return startIsTop ? (hidesAbove, hidesBelow) : (hidesBelow, hidesAbove)
    }

    var fadeForTesting: CAGradientLayer { fade.layer }

    var fadedEdgesForTesting: (start: Bool, end: Bool) {
        let colors = (fade.layer.colors as? [CGColor]) ?? []
        return (colors.first?.alpha == 0, colors.last?.alpha == 0)
    }
}
