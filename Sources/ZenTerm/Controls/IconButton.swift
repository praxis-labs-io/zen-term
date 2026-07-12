import AppKit

/// The shared rounded icon button across the chrome: an SF Symbol that's muted at rest,
/// brightens with a faint background on hover, and — when `isActive` — tints iris with a
/// faint iris background. Used by the footer dock toggles, the tab-bar "+", and the panel
/// corner controls (zoom / drawer-hide). Replaces the old per-site glyph buttons.
final class IconButton: NSView {
    /// Reassignable so a host can wire it after init (e.g. the panel zoom button, which
    /// targets a callback set later). Most callers pass it once via the initializer.
    var onClick: () -> Void
    private let icon = NSImageView()
    private var trackingArea: NSTrackingArea?
    private var isHovered = false { didSet { update() } }

    /// Iris tint + faint iris background when set — used by the dock's toggle buttons to
    /// show their overlay is open. Momentary buttons (corner controls, "+") leave it false.
    var isActive = false { didSet { update() } }

    init(
        symbol: String, size: NSSize = NSSize(width: 24, height: 24),
        pointSize: CGFloat = 12, weight: NSFont.Weight = .medium,
        accessibilityLabel label: String, onClick: @escaping () -> Void
    ) {
        self.onClick = onClick
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        // Prefer an SF Symbol; fall back to a bundled brand mark (e.g. "github", "git")
        // from the asset catalog — rendered as a template so it tints exactly like a symbol.
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        if let symbolImage = NSImage(systemSymbolName: symbol, accessibilityDescription: label) {
            icon.image = symbolImage.withSymbolConfiguration(config)
        } else if let assetImage = BrandMark.image(symbol) {
            assetImage.size = NSSize(width: pointSize + 2, height: pointSize + 2)
            icon.image = assetImage
        }
        icon.imageScaling = .scaleNone
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)
        translatesAutoresizingMaskIntoConstraints = false

        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(label)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: size.width),
            heightAnchor.constraint(equalToConstant: size.height),
            icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        update()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func mouseDown(with event: NSEvent) { onClick() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func accessibilityPerformPress() -> Bool { onClick(); return true }

    /// Re-apply the live chrome colors after a config change — no relaunch. `update()` already
    /// reads `Theme.current` fresh on every call; it just needs re-triggering since nothing else
    /// changed (hover/active state didn't) to fire it on its own.
    func reapplyTheme() { update() }

    private func update() {
        let bg: NSColor
        let tint: NSColor
        if isActive {
            let accent = Theme.current.chrome.accent.nsColor
            bg = accent.withAlphaComponent(0.15); tint = accent
        } else if isHovered {
            bg = Theme.current.chrome.ink(alpha: 0.10); tint = Theme.current.chrome.ink(alpha: 0.95)
        } else {
            bg = .clear; tint = Theme.current.chrome.ink(alpha: 0.55)
        }
        if let layer { Motion.ease(layer, keyPath: "backgroundColor", to: bg.cgColor) }
        icon.contentTintColor = tint  // NSImageView tint isn't layer-animatable; the shift is barely visible
    }
}
