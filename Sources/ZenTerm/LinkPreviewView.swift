import AppKit

final class LinkPreviewView: HoverCardView {
    static let maxTextWidth: CGFloat = 480

    private let text: NSTextField

    var urlForTesting: String { text.stringValue }

    init(url: String) {
        text = Self.makeLabel(url)
        super.init(frame: .zero)
        text.lineBreakMode = .byTruncatingMiddle
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
