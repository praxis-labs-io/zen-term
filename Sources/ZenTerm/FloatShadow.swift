import AppKit

/// Shared styling for floating cards (the ⌘P repo picker and the lazygit float): a dark
/// elevation shadow and a subtle neutral edge, in place of a colored ring.
enum FloatShadow {
    /// Subtle neutral hairline on the card edge (no color), for crispness over the shadow.
    static let edge = NSColor(white: 1, alpha: 0.08)

    /// Cast a dark drop shadow from the card itself — the same pattern as the pane focus
    /// glow, which works: shadow on the rounded, layer-backed view with `masksToBounds =
    /// false` (masking would clip the shadow). The card's content is inset from the corners,
    /// so the rounded background still reads without the mask. Strong + offset so it shows
    /// over the dark panes.
    static func applyShadow(to card: NSView) {
        guard let layer = card.layer else { return }
        layer.masksToBounds = false
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOpacity = 0.5
        layer.shadowRadius = 14
        layer.shadowOffset = CGSize(width: 0, height: -12)   // AppKit y-up: cast downward
    }
}
