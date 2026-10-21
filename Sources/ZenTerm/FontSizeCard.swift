import AppKit

/// Updates in place because held zoom chords auto-repeat and a card per step would stack.
final class FontSizeCard: ShadowCardView {
    private let label: NSTextField

    private static let font: NSFont = ChromeType.font(.body, weight: .semibold, face: .digits)

    init(text: String) {
        label = NSTextField(labelWithString: text)
        super.init(frame: .zero)

        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = ChromeMetrics.Radius.surface
        layer?.backgroundColor = Theme.current.chrome.background.nsColor.cgColor
        layer?.borderWidth = ChromeMetrics.Border.width
        layer?.borderColor = FloatShadow.edge.cgColor
        FloatShadow.apply(.float, to: self)

        label.font = Self.font
        label.textColor = Theme.current.chrome.ink(.normal)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: ChromeMetrics.Spacing.s12),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -ChromeMetrics.Spacing.s12),
            label.topAnchor.constraint(equalTo: topAnchor, constant: ChromeMetrics.Spacing.s8),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -ChromeMetrics.Spacing.s8),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(text: String) { label.stringValue = text }

    func reapplyTheme() {
        layer?.backgroundColor = Theme.current.chrome.background.nsColor.cgColor
        layer?.borderColor = FloatShadow.edge.cgColor
        FloatShadow.apply(.float, to: self)
        label.textColor = Theme.current.chrome.ink(.normal)
    }
}
