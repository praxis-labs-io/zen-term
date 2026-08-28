import AppKit

/// Shared styling for floating cards: a dark elevation shadow, and a subtle neutral edge for the
/// cards that don't claim focus. A card that takes focus from the pane behind it wears the accent
/// ring instead — see `CardChrome.apply(halo:)`.
enum FloatShadow {
    /// Subtle neutral hairline on the card edge (no color), for crispness over the shadow.
    static var edge: NSColor { Theme.current.chrome.fill(alpha: ChromeTheme.hairline) }

    /// Cast a dark drop shadow from the card itself, with `masksToBounds = false` (masking
    /// would clip the shadow). The card's content is inset from the corners, so the rounded
    /// background still reads without the mask. Strong + offset so it shows over the dark panes.
    ///
    /// Set via `NSView.shadow`, never `layer.shadow*`: AppKit owns a layer-backed view's
    /// backing layer, and inserting a subtree into the window re-syncs view properties over
    /// it — a nil `NSView.shadow` zeroes any `shadowOpacity` written directly to the layer.
    /// That silently deleted every overlay card's shadow (cards are always nested in their
    /// overlay's subtree), while directly-inserted views (toasts) happened to escape.
    static func applyShadow(to card: NSView) {
        card.layer?.masksToBounds = false
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
        shadow.shadowBlurRadius = 14
        shadow.shadowOffset = NSSize(width: 0, height: -12)  // AppKit y-up: cast downward
        card.shadow = shadow
    }
}
