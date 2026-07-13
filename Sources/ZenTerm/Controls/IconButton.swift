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

    /// A small accent dot at the top-right corner, shown when the button stands in for a
    /// hidden surface that has a live process (a closed-but-busy drawer, ZEN-107).
    var showsActivity = false { didSet { activityDot.isHidden = !showsActivity } }
    /// Test hook: whether the activity dot is currently rendered (ZEN-107).
    var activityDotHiddenForTesting: Bool { activityDot.isHidden }
    private let activityDot = NSView()
    private static let dotDiameter: CGFloat = 4
    /// Distance from the button's top-right corner to the dot's center — inset so the dot reads as
    /// a small badge tucked inside the corner rather than sitting in the rounded-off corner region.
    private static let dotInset: CGFloat = dotDiameter / 2 + 2

    /// The hover-tooltip label, and an optional resolver for its keybind glyph — evaluated at hover
    /// time so it reflects the live keymap (ZEN-42). A branded `ChromeTooltip`, not the native
    /// `toolTip`, which is OS-drawn and unaware of the chrome.
    private let tooltipLabel: String
    private let tooltipShortcut: (() -> String?)?

    init(
        symbol: String, size: NSSize = NSSize(width: 24, height: 24),
        pointSize: CGFloat = 12, weight: NSFont.Weight = .medium,
        accessibilityLabel label: String, shortcut: (() -> String?)? = nil,
        onClick: @escaping () -> Void
    ) {
        self.onClick = onClick
        tooltipLabel = label
        tooltipShortcut = shortcut
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
        TooltipPresenter.shared.scheduleShow(for: self, label: tooltipLabel, shortcut: tooltipShortcut?())
    }
    override func mouseExited(with event: NSEvent) {
        isHovered = false
        TooltipPresenter.shared.hide(for: self)
    }
    override func mouseDown(with event: NSEvent) {
        TooltipPresenter.shared.hide(for: self)  // a click dismisses the tooltip
        onClick()
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func accessibilityPerformPress() -> Bool { onClick(); return true }

    /// Drop the tooltip if this button leaves the window (e.g. the dock rebuilds its floats).
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { TooltipPresenter.shared.hide(for: self) }
    }

    /// Test hooks for the tooltip content (ZEN-42).
    var tooltipLabelForTesting: String { tooltipLabel }
    var tooltipShortcutForTesting: String? { tooltipShortcut?() }

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
        activityDot.layer?.backgroundColor = Theme.current.chrome.accent.nsColor.cgColor
    }
}
