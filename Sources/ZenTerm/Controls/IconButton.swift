import AppKit

/// The shared rounded icon button across the chrome: an SF Symbol that's muted at rest,
/// brightens with a faint background on hover, and — when `isActive` — tints iris with a
/// faint iris background. Used by the footer dock toggles, the tab-bar "+", and the panel
/// corner controls (zoom / drawer-hide). Replaces the old per-site glyph buttons.
/// An image view that lays out by its own bounds. `NSImageView` derives alignment insets from an
/// SF Symbol's baseline metadata — off-centre, and different per glyph — so an unmodified one hangs
/// symbols unevenly beside a brand mark, whose SVG carries no such metadata. Setting the image's
/// `alignmentRect` does not reach this; the insets have to be overridden on the view.
private final class GlyphView: NSImageView {
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsets() }
}

final class IconButton: NSView {
    /// Reassignable so a host can wire it after init (e.g. the panel zoom button, which
    /// targets a callback set later). Most callers pass it once via the initializer.
    var onClick: () -> Void
    private let icon = GlyphView()
    private var trackingArea: NSTrackingArea?
    private var isHovered = false { didSet { update() } }

    /// Iris tint + faint iris background when set — used by the dock's toggle buttons to
    /// show their overlay is open. Momentary buttons (corner controls, "+") leave it false.
    var isActive = false { didSet { update() } }

    /// A small accent dot at the top-right corner, shown when the button stands in for a
    /// hidden surface that has a live process (a closed-but-busy drawer).
    var showsActivity = false { didSet { activityDot.isHidden = !showsActivity } }
    /// Test hook: whether the activity dot is currently rendered.
    var activityDotHiddenForTesting: Bool { activityDot.isHidden }
    private let activityDot = NSView()
    private static let dotDiameter: CGFloat = 4
    /// Distance from the button's top-right corner to the dot's center — inset so the dot reads as
    /// a small badge tucked inside the corner rather than sitting in the rounded-off corner region.
    private static let dotInset: CGFloat = dotDiameter / 2 + 2

    /// The hover-tooltip wiring — a branded `ChromeTooltip` (not the OS-drawn `toolTip`), evaluated at
    /// hover time so its keybind reflects the live keymap. Shared with `TabBarView.Chip`.
    private let tooltip: TooltipHost

    /// Whether the button carries a faint fill at rest instead of reading as a bare glyph. Off by
    /// default, which is every toolbar and tab-bar button: they sit on chrome and earn their box on
    /// hover. On for a button standing beside an input it has to match the weight of, where a bare
    /// glyph reads as decoration rather than a control.
    private let restsFilled: Bool

    init(
        symbol: String, size: NSSize = NSSize(width: 24, height: 24),
        pointSize: CGFloat = 12, weight: NSFont.Weight = .medium,
        accessibilityLabel label: String, shortcut: (() -> String?)? = nil,
        restsFilled: Bool = false,
        onClick: @escaping () -> Void
    ) {
        self.onClick = onClick
        self.restsFilled = restsFilled
        tooltip = TooltipHost(label: label, shortcut: shortcut)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        // An SF Symbol, else a bundled brand mark — resolved through the catalog, which owns that
        // fallback. The mark is sized to match the symbols beside it, not to its nominal box.
        // (The button carries the accessibility label itself, below, so the image needs none.)
        icon.image = IconCatalog.image(
            symbol, pointSize: pointSize, weight: weight,
            brandSize: IconCatalog.brandBoxMatching(pointSize: pointSize))
        icon.imageScaling = .scaleNone
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)
        translatesAutoresizingMaskIntoConstraints = false

        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(label)

        activityDot.wantsLayer = true
        activityDot.layer?.cornerRadius = Self.dotDiameter / 2
        activityDot.isHidden = true
        activityDot.translatesAutoresizingMaskIntoConstraints = false
        addSubview(activityDot)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: size.width),
            heightAnchor.constraint(equalToConstant: size.height),
            icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            activityDot.widthAnchor.constraint(equalToConstant: Self.dotDiameter),
            activityDot.heightAnchor.constraint(equalToConstant: Self.dotDiameter),
            // Inset from the corner so the dot clears the button's 6pt corner radius (and any
            // clipping) and reads as a fully-visible top-right badge.
            activityDot.centerXAnchor.constraint(equalTo: trailingAnchor, constant: -Self.dotInset),
            activityDot.centerYAnchor.constraint(equalTo: topAnchor, constant: Self.dotInset),
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

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        tooltip.show(from: self)
    }
    override func mouseExited(with event: NSEvent) {
        isHovered = false
        tooltip.hide(from: self)
    }
    override func mouseDown(with event: NSEvent) {
        tooltip.hide(from: self)  // a click dismisses the tooltip
        onClick()
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func accessibilityPerformPress() -> Bool { onClick(); return true }

    /// Drop the tooltip if this button leaves the window (e.g. the dock rebuilds its floats).
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { tooltip.hide(from: self) }
    }

    /// Test hook: the tint actually painted on the glyph, read off the image view rather than the
    /// inputs that chose it.
    var iconTintForTesting: NSColor? { icon.contentTintColor }

    /// Test hooks for the tooltip content.

    var tooltipLabelForTesting: String { tooltip.label }
    var tooltipShortcutForTesting: String? { tooltip.shortcutForTesting }

    /// Re-apply the live chrome colors after a config change — no relaunch. `update()` already
    /// reads `Theme.current` fresh on every call; it just needs re-triggering since nothing else
    /// changed (hover/active state didn't) to fire it on its own.
    func reapplyTheme() { update() }

    private func update() {
        let chrome = Theme.current.chrome
        let bg: NSColor
        let tint: NSColor
        if isActive {
            bg = chrome.fill(.active); tint = chrome.accent.nsColor
        } else if isHovered {
            bg = chrome.fill(.hover); tint = chrome.ink(.normal)
        } else {
            bg = restsFilled ? chrome.fill(.rest) : .clear
            tint = chrome.ink(.subtle)
        }
        if let layer { Motion.ease(layer, keyPath: "backgroundColor", to: bg.cgColor) }
        icon.contentTintColor = tint  // NSImageView tint isn't layer-animatable; the shift is barely visible
        activityDot.layer?.backgroundColor = Theme.current.chrome.accent.nsColor.cgColor
    }
}
