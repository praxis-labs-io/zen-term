import AppKit

/// The inner padding between a card's border and the terminal inside it, painted as a rounded rect
/// with the terminal's frame punched out of it.
///
/// It exists for the translucent case. While the background is solid, whatever fills the card fills
/// the padding too and there is nothing to do. Below alpha 1 that fill has to stop, or it repaints
/// the terminal background behind a surface that is now see-through and nothing shows through — so
/// this takes over the border region alone, at the same alpha the terminal blends at, and the two
/// read as one surface instead of the ring sitting a shade lighter (ZEN-282).
///
/// A view rather than a `CAShapeLayer` hand-inserted under the host's own sublayers, where AppKit
/// owns the ordering and a later subview insertion can reshuffle it.
///
/// Shared by `PanelHostView` (a pane or drawer) and `SurfaceFloatOverlay` (a tool float).
final class RingFillView: NSView {
    var color: NSColor = .clear { didSet { needsDisplay = true } }
    /// The card's corner radius, so the painted ring follows the same curve as the border it fills
    /// against. Set by the host — a pane's is 12, a float's 14.
    var cornerRadius: CGFloat = 0 { didSet { needsDisplay = true } }
    /// The terminal, whose frame is the part left unpainted. Read at draw time rather than
    /// stored, because layout runs top-down and this view's owner is laid out first — the host
    /// marks this view for redisplay from its own `layout()` and lets the draw read a settled
    /// frame. Setting the hole from the host instead reads a frame that is still stale, which
    /// shipped a panel whose padding went unpainted until some later layout pass corrected it.
    weak var contentView: NSView?

    override func draw(_ dirtyRect: NSRect) {
        guard let contentView else { return }
        // Converted from the content's OWN space, not `frame` out of a shared superview: both
        // hosts happen to make the two siblings today, and reading it that way would punch a
        // silently wrong hole the first time the terminal is wrapped or reparented — a defect
        // that looks like a ring bug rather than a hierarchy one.
        let hole = convert(contentView.bounds, from: contentView)
        let path = NSBezierPath(
            roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius)
        path.append(NSBezierPath(rect: hole))
        path.windingRule = .evenOdd
        color.setFill()
        path.fill()
    }
}
