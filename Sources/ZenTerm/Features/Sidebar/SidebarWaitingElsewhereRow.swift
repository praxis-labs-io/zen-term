import AppKit

final class SidebarWaitingElsewhereRow: SidebarJumpRow {
    private let dot = StateDot(.blocked)

    static let height: CGFloat = ChromeMetrics.Height.control

    static func text(agents: Int, windows: Int) -> String {
        "\(agents) waiting in \(windows > 1 ? "other windows" : "another window")"
    }

    init(onActivate: @escaping () -> Void) {
        super.init(
            Content(title: "", ink: .muted), tooltip: "Jump to the agent waiting longest", onActivate: onActivate)
        heightAnchor.constraint(equalToConstant: Self.height).isActive = true
        accessories = [dot]
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func render(agents: Int, windows: Int) {
        let text = Self.text(agents: agents, windows: windows)
        guard text != content.title else { return }
        render(Content(title: text, ink: .muted))
    }

    var textForTesting: String { content.title }

    var dotForTesting: StateDot { dot }
}
