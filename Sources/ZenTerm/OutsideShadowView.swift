import AppKit

// A layer shadow fills `shadowPath` under the card, which washes a see-through card, so the card is clipped out at draw time.
final class OutsideShadowView: NSView {
    var color: NSColor = .clear { didSet { needsDisplay = true } }
    var outset: CGFloat = 0 { didSet { needsDisplay = true } }
    var cornerRadius: CGFloat = 0 { didSet { needsDisplay = true } }
    // `CGContext` blur renders at a different scale from `CALayer.shadowRadius`; values don't carry across.
    var blur: CGFloat = 8 { didSet { needsDisplay = true } }
    var offset: NSSize = .zero { didSet { needsDisplay = true } }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let card = bounds.insetBy(dx: outset, dy: outset)
        guard card.width > 0, card.height > 0 else { return }
        let radius = min(cornerRadius, card.width / 2, card.height / 2)
        let path = CGPath(
            roundedRect: card, cornerWidth: radius, cornerHeight: radius, transform: nil)

        context.saveGState()
        context.addRect(bounds)
        context.addPath(path)
        context.clip(using: .evenOdd)
        context.setShadow(offset: offset, blur: blur, color: color.cgColor)
        context.setFillColor(color.cgColor)
        context.addPath(path)
        context.fillPath()
        context.restoreGState()
    }
}
