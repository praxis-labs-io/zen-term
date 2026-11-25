import AppKit

final class HintFooter: NSView, ThemeReapplying {
    static let height = ChromeMetrics.Border.width + ChromeMetrics.Height.lg

    struct Hint: Equatable {
        let keys: String
        let label: String
    }

    private let hairline = NSView()
    private let pairs = NSStackView()
    private var labels: [NSTextField] = []
    private(set) var hints: [Hint] = []

    init(_ hints: [Hint], trailingInset: CGFloat = ChromeMetrics.Spacing.modalInsets.right) {
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
            pairs.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -trailingInset),
            pairs.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: trailingInset),
            pairs.centerYAnchor.constraint(
                equalTo: centerYAnchor, constant: ChromeMetrics.Border.width / 2),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func setHints(_ hints: [Hint]) {
        guard hints != self.hints else { return }
        self.hints = hints
        pairs.arrangedSubviews.forEach { $0.removeFromSuperview() }
        labels = []
        hints.forEach { pairs.addArrangedSubview(makeItem($0)) }
    }

    func reapplyTheme() {
        let chrome = Theme.current.chrome
        hairline.layer?.backgroundColor = chrome.fill(alpha: ChromeTheme.hairline).cgColor
        labels.forEach { $0.textColor = chrome.ink(.muted) }
    }

    private func makeItem(_ hint: Hint) -> NSView {
        let keycap = KeycapView(shortcut: hint.keys)
        let label = NSTextField(labelWithString: hint.label)
        label.font = ChromeType.font(.caption, weight: .medium)
        label.textColor = Theme.current.chrome.ink(.muted)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        labels.append(label)
        let item = NSStackView(views: [label, keycap])
        item.orientation = .horizontal
        item.spacing = ChromeMetrics.Spacing.s6
        item.alignment = .centerY
        return item
    }
}
