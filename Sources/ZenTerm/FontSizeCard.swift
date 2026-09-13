import AppKit

/// Updates in place because held zoom chords auto-repeat and a card per step would stack.
final class FontSizeCard: ShadowCardView {
    private let label: NSTextField

    /// Tabular digits so the label does not shift sideways on every step.
    private static let font: NSFont = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)

    init(text: String) {
        label = NSTextField(labelWithString: text)
        super.init(frame: .zero)

        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.backgroundColor = Theme.current.chrome.background.nsColor.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = FloatShadow.edge.cgColor
        FloatShadow.applyShadow(to: self)

        label.font = Self.font
        label.textColor = Theme.current.chrome.foreground.nsColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(text: String) { label.stringValue = text }

    func reapplyTheme() {
        layer?.backgroundColor = Theme.current.chrome.background.nsColor.cgColor
        layer?.borderColor = FloatShadow.edge.cgColor
        label.textColor = Theme.current.chrome.foreground.nsColor
    }
}
