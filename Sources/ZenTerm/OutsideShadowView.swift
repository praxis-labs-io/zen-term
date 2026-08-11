import AppKit

/// A drop shadow drawn *around* a card rather than cast by it — the outward half only, with
/// nothing painted where the card itself sits.
///
/// A layer shadow can't do this. Core Animation renders `shadowOpacity` by *filling* `shadowPath`
/// and blurring the result, so the shadow covers the card's whole interior as well as haloing it.
/// That is free while the card is opaque and paints over it, and becomes a wash across the interior
/// the moment `background-alpha` makes it see-through (for the pane focus glow, and for
/// the float's much darker elevation shadow).
///
/// Reshaping the path into a ring doesn't work, and fails in a way that looks like a tuning problem
/// rather than a design one: a drop shadow decays outward *from* a filled silhouette, so a ring
/// makes the glow ramp **up** as it travels out instead of fading, landing as a huge dense cloud at
/// any inflation. The silhouette has to stay the card, and the cut has to happen at draw time —
/// hence the clip below, which keeps the falloff exactly as it was and removes only the half that
/// fell inside.
///
/// An `NSView` can't paint outside its own bounds, so the host mounts this outset past the card by
/// `outset` on every side and the shadow has room to reach.
final class OutsideShadowView: NSView {
    var color: NSColor = .clear { didSet { needsDisplay = true } }
    /// How far this view is outset past the card it surrounds, i.e. the inset from its own bounds
    /// back to the card's edge.
    var outset: CGFloat = 0 { didSet { needsDisplay = true } }
    /// The card's corner radius, so the silhouette matches the card exactly.
    var cornerRadius: CGFloat = 0 { didSet { needsDisplay = true } }
    /// Blur radius, in `CGContext` terms. Not interchangeable with `CALayer.shadowRadius` — the two
    /// render at different scales, so a layer shadow's value can't be carried across and has to be
    /// re-calibrated by eye. Measured falloff just outside the card edge: 6 peaks at 0.118 alpha and
    /// dies by 6pt, 12 peaks at 0.133 and carries to 10pt.
    var blur: CGFloat = 8 { didSet { needsDisplay = true } }
    /// Shadow offset, AppKit y-up (negative y casts downward). Zero for a focus glow that surrounds
    /// the card evenly; offset for an elevation shadow that reads as light from above.
    var offset: NSSize = .zero { didSet { needsDisplay = true } }

    /// Decoration only — never take a click off the card it surrounds.
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
        context.clip(using: .evenOdd)  // everything except the card itself
        context.setShadow(offset: offset, blur: blur, color: color.cgColor)
        context.setFillColor(color.cgColor)
        context.addPath(path)
        context.fillPath()  // clipped away; only the shadow it throws survives
        context.restoreGState()
    }
}
