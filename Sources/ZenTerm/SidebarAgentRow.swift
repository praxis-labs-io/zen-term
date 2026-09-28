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
        case .done, .failed: return 2
        case .idle: return 3
        }
    }

    var summary: String {
        switch self {
        case .waiting: return "Waiting"
        case .working: return "Working"
        case .done: return "Done"
        case .failed: return "Exited"
        case .idle: return "Idle"
        }
    }
}

final class SidebarAgentRow: SidebarJumpRow {
    private let summaryLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let glyphSlot = NSView()
    private let dot = NSView()
    private let spinner = Spinner()
    private var item: SidebarAgentItem?

    static let height: CGFloat = 47
    private static let jumpHint = "Jump to agent"
    private static let inset: CGFloat = 10
    private static let top: CGFloat = 7
    private static let glyphSize = NSSize(width: 14, height: 16)
    private static let glyphGap: CGFloat = 8
    private static let lineGap: CGFloat = 3
    private static let dotDiameter: CGFloat = 7

    init(onActivate: @escaping () -> Void) {
        super.init(tooltip: Self.jumpHint, onActivate: onActivate)

        summaryLabel.font = .systemFont(ofSize: 12)
        detailLabel.font = .systemFont(ofSize: 11)
        for label in [summaryLabel, detailLabel] {
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
        }

        dot.wantsLayer = true
        dot.layer?.cornerRadius = Self.dotDiameter / 2
        glyphSlot.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glyphSlot)
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
            glyphSlot.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.inset),
            glyphSlot.topAnchor.constraint(equalTo: topAnchor, constant: Self.top),
            glyphSlot.widthAnchor.constraint(equalToConstant: Self.glyphSize.width),
            glyphSlot.heightAnchor.constraint(equalToConstant: Self.glyphSize.height),
            dot.widthAnchor.constraint(equalToConstant: Self.dotDiameter),
            dot.heightAnchor.constraint(equalToConstant: Self.dotDiameter),
            summaryLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.inset),
            summaryLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: glyphSlot.leadingAnchor, constant: -Self.glyphGap),
            summaryLabel.centerYAnchor.constraint(equalTo: glyphSlot.centerYAnchor),
            detailLabel.leadingAnchor.constraint(equalTo: summaryLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(lessThanOrEqualTo: glyphSlot.leadingAnchor, constant: -Self.glyphGap),
            detailLabel.topAnchor.constraint(equalTo: glyphSlot.bottomAnchor, constant: Self.lineGap),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func render(_ item: SidebarAgentItem) {
        guard item != self.item else { return }
        self.item = item
        summaryLabel.stringValue = item.summary
        tooltip.label = item.message ?? Self.jumpHint
        tooltip.style = item.message == nil ? .line : .paragraph
        tooltip.relabel(from: self)
        detailLabel.stringValue = item.detail
        setAccessibilityLabel(item.message ?? item.summary)
        setAccessibilityValue(item.detail)
        dot.isHidden = item.state == .working
        spinner.isHidden = item.state != .working
        spinner.isSpinning = item.state == .working
        reapplyTheme()
    }

    var itemForTesting: SidebarAgentItem? { item }

    var summaryTextForTesting: String { summaryLabel.stringValue }

    override func reapplyTheme() {
        let ink = (item?.state ?? .idle).ink
        summaryLabel.textColor = ink
        detailLabel.textColor = Theme.current.chrome.ink(.muted)
        dot.layer?.backgroundColor = ink.cgColor
        spinner.reapplyTheme()
        super.reapplyTheme()
    }
}
