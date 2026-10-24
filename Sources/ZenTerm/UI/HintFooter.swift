import AppKit

final class HintFooter: NSView {
    struct Hint {
        let keys: String
        let label: String
    }

    private let hairline = NSView()
    private var labels: [NSTextField] = []
    private var keycaps: [KeycapView] = []
    private var itemsByLabel: [String: NSView] = [:]

    init(_ hints: [Hint]) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        hairline.wantsLayer = true
        hairline.layer?.backgroundColor = Theme.current.chrome.fill(alpha: ChromeTheme.hairline).cgColor
        hairline.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hairline)

        let pairs = makePairs(hints)
        pairs.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pairs)

        NSLayoutConstraint.activate([
            hairline.topAnchor.constraint(equalTo: topAnchor),
            hairline.leadingAnchor.constraint(equalTo: leadingAnchor),
            hairline.trailingAnchor.constraint(equalTo: trailingAnchor),
            hairline.heightAnchor.constraint(equalToConstant: ChromeMetrics.Border.width),
            heightAnchor.constraint(equalToConstant: ChromeMetrics.Border.width + ChromeMetrics.Height.lg),
            pairs.centerXAnchor.constraint(equalTo: centerXAnchor),
            pairs.centerYAnchor.constraint(
                equalTo: centerYAnchor, constant: ChromeMetrics.Border.width / 2),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func setHint(_ label: String, isShown: Bool) {
        itemsByLabel[label]?.isHidden = !isShown
    }

    func reapplyTheme() {
        let chrome = Theme.current.chrome
        hairline.layer?.backgroundColor = chrome.fill(alpha: ChromeTheme.hairline).cgColor
        labels.forEach { $0.textColor = chrome.ink(.muted) }
        keycaps.forEach { $0.reapplyTheme() }
    }

    private func makePairs(_ hints: [Hint]) -> NSStackView {
        let items = hints.map { hint -> NSView in
            let keycap = KeycapView(shortcut: hint.keys)
            let label = NSTextField(labelWithString: hint.label)
            label.font = ChromeType.font(.caption, weight: .medium)
            label.textColor = Theme.current.chrome.ink(.muted)
            keycaps.append(keycap)
            labels.append(label)
            let item = NSStackView(views: [keycap, label])
            item.orientation = .horizontal
            item.spacing = ChromeMetrics.Spacing.s4
            item.alignment = .centerY
            itemsByLabel[hint.label] = item
            return item
        }
        let stack = NSStackView(views: items)
        stack.orientation = .horizontal
        stack.spacing = ChromeMetrics.Spacing.s16
        stack.alignment = .centerY
        return stack
    }
}
