import AppKit

final class HintFooter: NSView, ThemeReapplying {
    static let height = ChromeMetrics.Border.width + ChromeMetrics.Height.lg

    struct Hint: Equatable {
        let keys: String
        let label: String
    }

    final class Item: NSStackView, ThemeReapplying {
        private let label: NSTextField

        init(_ hint: Hint) {
            label = NSTextField(labelWithString: hint.label)
            label.font = ChromeType.font(.caption, weight: .medium)
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            super.init(frame: .zero)
            addArrangedSubview(label)
            addArrangedSubview(KeycapView(shortcut: hint.keys))
            orientation = .horizontal
            spacing = ChromeMetrics.Spacing.s6
            alignment = .centerY
            reapplyTheme()
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        func reapplyTheme() { label.textColor = Theme.current.chrome.ink(.muted) }
    }

    private let hairline = NSView()
    private let pairs = NSStackView()
    private(set) var hints: [Hint] = []

    enum Side { case leading, trailing }

    init(_ hints: [Hint], inset: CGFloat = ChromeMetrics.Spacing.modalInsets.right, side: Side = .trailing) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        hairline.wantsLayer = true
        hairline.layer?.backgroundColor = Theme.current.chrome.fill(alpha: ChromeTheme.hairline).cgColor
        hairline.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hairline)

        pairs.orientation = .horizontal
        pairs.spacing = ChromeMetrics.Spacing.s16
        pairs.alignment = .centerY
        pairs.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pairs)
        setHints(hints)

        NSLayoutConstraint.activate([
            hairline.topAnchor.constraint(equalTo: topAnchor),
            hairline.leadingAnchor.constraint(equalTo: leadingAnchor),
            hairline.trailingAnchor.constraint(equalTo: trailingAnchor),
            hairline.heightAnchor.constraint(equalToConstant: ChromeMetrics.Border.width),
            heightAnchor.constraint(equalToConstant: Self.height),
            side == .trailing
                ? pairs.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset)
                : pairs.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            pairs.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: inset),
            pairs.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -inset),
            pairs.centerYAnchor.constraint(
                equalTo: centerYAnchor, constant: ChromeMetrics.Border.width / 2),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func setHints(_ hints: [Hint]) {
        guard hints != self.hints else { return }
        self.hints = hints
        pairs.arrangedSubviews.forEach { $0.removeFromSuperview() }
        hints.forEach { pairs.addArrangedSubview(Item($0)) }
    }

    var hintsWidth: CGFloat { pairs.fittingSize.width.rounded(.up) }

    func reapplyTheme() {
        let chrome = Theme.current.chrome
        hairline.layer?.backgroundColor = chrome.fill(alpha: ChromeTheme.hairline).cgColor
        pairs.arrangedSubviews.forEach { ($0 as? Item)?.reapplyTheme() }
    }
}
