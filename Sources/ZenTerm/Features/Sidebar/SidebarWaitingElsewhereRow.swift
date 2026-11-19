import AppKit

final class SidebarWaitingElsewhereRow: SidebarJumpRow {
    private let dot = NSView()

    static let height: CGFloat = ChromeMetrics.Height.control
    private static let dotDiameter: CGFloat = 7

    static func text(agents: Int, windows: Int) -> String {
        "\(agents) waiting in \(windows > 1 ? "other windows" : "another window")"
    }

    init(onActivate: @escaping () -> Void) {
        super.init(
            Content(title: "", ink: .muted), tooltip: "Jump to the agent waiting longest", onActivate: onActivate)
        dot.wantsLayer = true
        dot.layer?.cornerRadius = ChromeMetrics.Radius.capsule(Self.dotDiameter)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            dot.widthAnchor.constraint(equalToConstant: Self.dotDiameter),
            dot.heightAnchor.constraint(equalToConstant: Self.dotDiameter),
        ])
        accessories = [dot]
        reapplyTheme()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func render(agents: Int, windows: Int) {
        let text = Self.text(agents: agents, windows: windows)
        guard text != content.title else { return }
        render(Content(title: text, ink: .muted))
    }

    var textForTesting: String { content.title }

    override func reapplyTheme() {
        dot.layer?.backgroundColor = AttentionTone.waiting.ink.cgColor
        super.reapplyTheme()
    }
}
