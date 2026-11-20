import AppKit

struct SidebarAgentItem: Equatable {
    let id: SurfaceID
    let state: AttentionTone
    let summary: String
    let detail: String
    let message: String?

    static func summaryLine(of message: String) -> String {
        let firstLine = message.trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix { !$0.isNewline }
            .trimmingCharacters(in: .whitespaces)
        var index = firstLine.startIndex
        while let stop = firstLine[index...].firstIndex(where: { ".!?".contains($0) }) {
            let after = firstLine.index(after: stop)
            guard after < firstLine.endIndex else { return firstLine }
            if firstLine[after].isWhitespace { return String(firstLine[...stop]) }
            index = after
        }
        return firstLine
    }
}

// The Agents list's own ordering and copy for the shared states.
extension AttentionTone {
    // Blocked and done share a rank, so waiting agents queue by age alone.
    var rank: Int {
        switch self {
        case .blocked, .done: return 0
        case .working: return 1
        case .idle: return 2
        }
    }

    var summary: String {
        switch self {
        case .blocked: return "Waiting"
        case .done: return "Done"
        case .working: return "Working"
        case .idle: return "Idle"
        }
    }
}

final class SidebarAgentRow: SidebarJumpRow {
    private let glyphSlot = NSView()
    private let dot = StateDot()
    private let spinner = Spinner()
    private var item: SidebarAgentItem?

    static let height: CGFloat = ChromeMetrics.Height.xl
    private static let jumpHint = "Jump to agent"
    private static let glyphSize = NSSize(width: 14, height: 16)

    init(onActivate: @escaping () -> Void) {
        super.init(tooltip: Self.jumpHint, onActivate: onActivate)

        spinner.role = \.working
        for glyph in [dot, spinner] {
            glyph.translatesAutoresizingMaskIntoConstraints = false
            glyphSlot.addSubview(glyph)
            NSLayoutConstraint.activate([
                glyph.trailingAnchor.constraint(equalTo: glyphSlot.trailingAnchor),
                glyph.centerYAnchor.constraint(equalTo: glyphSlot.centerYAnchor),
            ])
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            glyphSlot.widthAnchor.constraint(equalToConstant: Self.glyphSize.width),
            glyphSlot.heightAnchor.constraint(equalToConstant: Self.glyphSize.height),
        ])
        accessories = [glyphSlot]
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func render(_ item: SidebarAgentItem) {
        guard item != self.item else { return }
        self.item = item
        render(Content(title: item.summary, subtitle: item.detail))
        tooltip?.label = item.message ?? Self.jumpHint
        tooltip?.style = item.message == nil ? .line : .paragraph
        tooltip?.relabel(from: self)
        announce(item)
        setAccessibilityValue(item.detail)
        dot.state = item.state.dot
        spinner.isHidden = item.state != .working
        spinner.isSpinning = item.state == .working
    }

    var itemForTesting: SidebarAgentItem? { item }

    var dotForTesting: StateDot { dot }

    var isSpinningForTesting: Bool { !spinner.isHidden && spinner.isSpinning }

    var summaryTextForTesting: String { content.title }

    override func reapplyTheme() {
        if let item {
            render(Content(title: item.summary, subtitle: item.detail))
            announce(item)
        }
        super.reapplyTheme()
    }

    // `render` labels the row with its title, the summary, which cuts a multi-sentence message short.
    private func announce(_ item: SidebarAgentItem) {
        setAccessibilityLabel(item.message ?? item.summary)
    }
}
