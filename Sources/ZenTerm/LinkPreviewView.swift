import AppKit

/// The hovered-link preview card: the shared hover-card idiom holding the destination URL and
/// nothing else. Distinct from `ChromeTooltip`, whose content is a fixed label + keycap with no
/// width budget: a URL is arbitrary-length program output, so it truncates mid-string against a
/// fixed budget instead of running the card across the window. Positioned by
/// `LinkPreviewPresenter` (ZEN-24).
final class LinkPreviewView: HoverCardView {
    /// The widest the URL may render before truncating. Middle truncation keeps the two ends a
    /// reader actually checks against a link: the host and the tail of the path.
    static let maxTextWidth: CGFloat = 480

    private let text: NSTextField

    var urlForTesting: String { text.stringValue }

    init(url: String) {
        text = Self.makeLabel(url)
        super.init(frame: .zero)
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
}
