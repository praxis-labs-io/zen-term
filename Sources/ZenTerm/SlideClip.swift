import AppKit

/// Clips a container to its bounds *expanded* by a margin while a panel slides in — hiding the panel
/// parked far outside (a full `slide` past the edge) without cutting the pane focus halo/shadow,
/// which `PanelHostView` deliberately lets escape a few points past its bounds. A hard
/// `masksToBounds` would clip that halo for the length of the slide; the expanded mask
/// spares it because the halo sits within `margin`, while the parked panel is far beyond it.
enum SlideClip {
    /// Kept-visible margin past the clipped view's bounds — covers the focus glow (shadow radius 6
    /// plus the pane border) with headroom, and stays far smaller than any drawer/split travel.
    static let margin: CGFloat = 10

    static func apply(to view: NSView) {
        view.wantsLayer = true
        let mask = CALayer()
        mask.backgroundColor = CGColor(gray: 1, alpha: 1)  // opaque = visible; outside the mask is clipped
        mask.frame = view.bounds.insetBy(dx: -margin, dy: -margin)
        view.layer?.mask = mask
    }

    static func remove(from view: NSView) { view.layer?.mask = nil }
}
