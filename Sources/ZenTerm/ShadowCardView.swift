import AppKit

/// A layer-backed card that keeps `layer.shadowPath` matched to its rounded bounds, so Core
/// Animation renders the shadow from an explicit path instead of an offscreen pass over the
/// layer contents. Every shadowed chrome card is (or subclasses) this view; the path re-derives
/// on each layout pass, covering both Auto Layout and frame-driven cards.
class ShadowCardView: NSView {
    override func layout() {
        super.layout()
        updateShadowPath()
    }

    /// Frame-driven cards (tooltip, dropdown list) never dirty Auto Layout, so a frame-size
    /// change must schedule the layout pass that refreshes the path.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    private func updateShadowPath() {
        guard let layer, bounds.width > 0, bounds.height > 0 else { return }
        // CGPath traps when the corner radius exceeds half the rect, so clamp for tiny frames.
        let radius = min(layer.cornerRadius, bounds.width / 2, bounds.height / 2)
        layer.shadowPath = CGPath(
            roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }
}
