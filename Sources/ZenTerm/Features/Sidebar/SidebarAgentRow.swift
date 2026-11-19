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
    var rank: Int {
        switch self {
        case .waiting: return 0
        case .working: return 1
        case .idle: return 2
        }
    }

    var summary: String {
        switch self {
        case .waiting: return "Waiting"
        case .working: return "Working"
        case .idle: return "Idle"
        }
    }
}

final class SidebarAgentRow: SidebarJumpRow {
    private let glyphSlot = NSView()
    private let dot = NSView()
    private let spinner = Spinner()
    private var item: SidebarAgentItem?

    static let height: CGFloat = ChromeMetrics.Height.xl
    private static let jumpHint = "Jump to agent"
    private static let glyphSize = NSSize(width: 14, height: 16)
    private static let dotDiameter: CGFloat = 7

    init(onActivate: @escaping () -> Void) {
        super.init(tooltip: Self.jumpHint, onActivate: onActivate)

        dot.wantsLayer = true
        dot.layer?.cornerRadius = ChromeMetrics.Radius.capsule(Self.dotDiameter)
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
            dot.widthAnchor.constraint(equalToConstant: Self.dotDiameter),
            dot.heightAnchor.constraint(equalToConstant: Self.dotDiameter),
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
        setAccessibilityLabel(item.message ?? item.summary)
        setAccessibilityValue(item.detail)
        dot.isHidden = item.state == .working
        spinner.isHidden = item.state != .working
        spinner.isSpinning = item.state == .working
        reapplyTheme()
    }

    var itemForTesting: SidebarAgentItem? { item }

    var summaryTextForTesting: String { content.title }

    override func reapplyTheme() {
        dot.layer?.backgroundColor = (item?.state ?? .idle).ink.cgColor
        super.reapplyTheme()
    }
}
