import AppKit

enum FloatShadow {
    static var edge: NSColor { Theme.current.chrome.fill(alpha: ChromeTheme.hairline) }

    /// Black is deliberately theme-independent. Set via `NSView.shadow`: subtree insertion zeroes `layer.shadow*`.
    static func applyShadow(to card: NSView) {
        card.layer?.masksToBounds = false
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
        shadow.shadowBlurRadius = 14
        shadow.shadowOffset = NSSize(width: 0, height: -12)
        card.shadow = shadow
    }
}
