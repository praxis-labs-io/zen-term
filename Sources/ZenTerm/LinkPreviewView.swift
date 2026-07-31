import AppKit

/// The hovered-link preview card: the chrome's card idiom (themed background + hairline edge +
/// a soft elevation shadow) holding the destination URL and nothing else. Distinct from
/// `ChromeTooltip`, whose content is a fixed label + keycap with no width budget: a URL is
/// arbitrary-length program output, so it truncates mid-string against a fixed budget instead of
/// running the card across the window. Positioned by `LinkPreviewPresenter` (ZEN-24).
final class LinkPreviewView: ShadowCardView {
    /// The widest the URL may render before truncating. Middle truncation keeps the two ends a
    /// reader actually checks against a link: the host and the tail of the path.
    static let maxTextWidth: CGFloat = 480

    private let text: NSTextField

    var urlForTesting: String { text.stringValue }

    init(url: String) {
        text = NSTextField(labelWithString: url)
        super.init(frame: .zero)
        // Framed directly by `LinkPreviewPresenter` (not Auto Layout), so leave the default
        // translatesAutoresizingMaskIntoConstraints = true.
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.backgroundColor = Theme.current.chrome.background.nsColor.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = FloatShadow.edge.cgColor
        // The same elevation as ChromeTooltip: it floats just above the hovered link, not over
        // the whole canvas. Black is a theme-independent shadow (the documented FloatShadow
        // exception), not a chrome color. Via `NSView.shadow`, not `layer.shadow*`, so AppKit's
        // view→layer re-sync can't zero it (see FloatShadow.applyShadow).
        layer?.masksToBounds = false
        let elevation = NSShadow()
        elevation.shadowColor = NSColor.black.withAlphaComponent(0.35)
        elevation.shadowBlurRadius = 8
        elevation.shadowOffset = NSSize(width: 0, height: -3)
        shadow = elevation

        text.font = .systemFont(ofSize: 11, weight: .medium)
        text.textColor = Theme.current.chrome.ink(alpha: 0.9)
        text.lineBreakMode = .byTruncatingMiddle
        // Must lose to the width cap or a long URL makes the constraints unsatisfiable.
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        text.translatesAutoresizingMaskIntoConstraints = false
        addSubview(text)
        NSLayoutConstraint.activate([
            text.widthAnchor.constraint(lessThanOrEqualToConstant: Self.maxTextWidth),
            text.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            text.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            text.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            text.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Never intercept the pointer — the preview is a passive label floating near the link.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
