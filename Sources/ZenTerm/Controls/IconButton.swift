import AppKit

// `NSImageView` takes alignment insets from SF Symbol baseline metadata, which hangs symbols off-centre beside brand marks.
private final class GlyphView: NSImageView {
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsets() }
}

final class IconButton: NSView {
    var onClick: () -> Void
    private let icon = GlyphView()
    private var trackingArea: NSTrackingArea?
    private var isHovered = false { didSet { update() } }

    var isActive = false { didSet { update() } }

    var showsActivity = false { didSet { activityDot.isHidden = !showsActivity } }

    /// Colors the same dot that already says "something is live here", so it says what rather than whether.
    var activityState: SurfaceAttention = .idle { didSet { update() } }
    var activityDotHiddenForTesting: Bool { activityDot.isHidden }
    var activityColorForTesting: NSColor { activityColor }
    private let activityDot = NSView()
    private static let dotDiameter: CGFloat = 4
    private static let dotInset: CGFloat = dotDiameter / 2 + 2

    private let tooltip: TooltipHost

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
        icon.image = IconCatalog.image(symbol, pointSize: pointSize, weight: weight)
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
            icon.widthAnchor.constraint(equalToConstant: size.width),
            icon.heightAnchor.constraint(equalToConstant: size.height),
            activityDot.widthAnchor.constraint(equalToConstant: Self.dotDiameter),
            activityDot.heightAnchor.constraint(equalToConstant: Self.dotDiameter),
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
        tooltip.hide(from: self)
        onClick()
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func accessibilityPerformPress() -> Bool { onClick(); return true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { tooltip.hide(from: self) }
    }

    var iconTintForTesting: NSColor? { icon.contentTintColor }

    var tooltipLabelForTesting: String { tooltip.label }
    var tooltipShortcutForTesting: String? { tooltip.shortcutForTesting }

    func reapplyTheme() { update() }

    private var activityColor: NSColor {
        let chrome = Theme.current.chrome
        switch activityState {
        case .completed: return chrome.positive.nsColor
        case .waiting: return chrome.attention.nsColor
        case .idle, .working: return chrome.accent.nsColor
        }
    }

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
        icon.contentTintColor = tint
        activityDot.layer?.backgroundColor = activityColor.cgColor
    }
}
