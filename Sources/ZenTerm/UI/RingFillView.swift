import AppKit

/// Paints a card's padding ring while translucent, so the terminal background is not painted twice.
final class RingFillView: NSView {
    var color: NSColor = .clear { didSet { needsDisplay = true } }
    var cornerRadius: CGFloat = 0 { didSet { needsDisplay = true } }
    /// Its frame is read at draw time because the host lays out before the terminal settles.
    weak var contentView: NSView?

    override func draw(_ dirtyRect: NSRect) {
        guard let contentView else { return }
        let hole = convert(contentView.bounds, from: contentView)
        let path = NSBezierPath(
            roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius)
        path.append(NSBezierPath(rect: hole))
        path.windingRule = .evenOdd
        color.setFill()
        path.fill()
    }
}
