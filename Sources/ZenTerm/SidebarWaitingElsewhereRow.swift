import AppKit

final class SidebarWaitingElsewhereRow: SidebarJumpRow {
    private let label = NSTextField(labelWithString: "")
    private let dot = NSView()

    static let height: CGFloat = 30
    private static let inset: CGFloat = 10
    private static let gap: CGFloat = 8
    private static let dotDiameter: CGFloat = 7

    static func text(agents: Int, windows: Int) -> String {
        "\(agents) waiting in \(windows > 1 ? "other windows" : "another window")"
    }

    init(onActivate: @escaping () -> Void) {
        super.init(tooltip: "Jump to the agent waiting longest", onActivate: onActivate)

        label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        dot.wantsLayer = true
        dot.layer?.cornerRadius = Self.dotDiameter / 2
        dot.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dot)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.inset),
            label.trailingAnchor.constraint(lessThanOrEqualTo: dot.leadingAnchor, constant: -Self.gap),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.inset),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: Self.dotDiameter),
            dot.heightAnchor.constraint(equalToConstant: Self.dotDiameter),
        ])
        reapplyTheme()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func render(agents: Int, windows: Int) {
        let text = Self.text(agents: agents, windows: windows)
        guard text != label.stringValue else { return }
        label.stringValue = text
        setAccessibilityLabel(text)
    }

    var textForTesting: String { label.stringValue }

    override func reapplyTheme() {
        label.textColor = Theme.current.chrome.ink(.muted)
        dot.layer?.backgroundColor = AttentionTone.waiting.ink.cgColor
        super.reapplyTheme()
    }
}
