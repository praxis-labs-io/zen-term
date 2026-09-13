import AppKit

/// An explicit `shadowPath` spares Core Animation an offscreen pass over the layer.
class ShadowCardView: NSView {
    override func layout() {
        super.layout()
        updateShadowPath()
    }

    /// Frame-driven cards never dirty Auto Layout, so a resize has to schedule the path refresh.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    /// Clamps the radius because `CGPath` traps on one over half the rect.
    private func updateShadowPath() {
        guard let layer else { return }
        guard bounds.width > 0, bounds.height > 0 else {
            layer.shadowPath = nil
            return
        }
        let radius = min(layer.cornerRadius, bounds.width / 2, bounds.height / 2)
        layer.shadowPath = CGPath(
            roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }
}
