import AppKit

/// A scroll view that fades whichever edge hides content, as the tab bar fades its ends.
final class FadingScrollView: NSScrollView {
    static let fadeDepth: CGFloat = 16

    private let fade = EdgeFade(axis: .vertical)
    private var isObserving = false

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
        let visible = documentVisibleRect
        let height = documentView?.frame.height ?? 0
        let nearOrigin = visible.minY > 0.5
        let nearEnd = height - visible.maxY > 0.5
        let hidesAbove = contentView.isFlipped ? nearOrigin : nearEnd
        let hidesBelow = contentView.isFlipped ? nearEnd : nearOrigin
        let startIsTop = layer?.contentsAreFlipped() ?? false
        fade.update(
            frame: bounds,
            start: (startIsTop ? hidesAbove : hidesBelow) ? Self.fadeDepth : 0,
            end: (startIsTop ? hidesBelow : hidesAbove) ? Self.fadeDepth : 0)
    }

    var fadeForTesting: CAGradientLayer { fade.layer }
}
