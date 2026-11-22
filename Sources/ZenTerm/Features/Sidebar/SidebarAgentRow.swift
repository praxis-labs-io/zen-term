import AppKit

struct SidebarAgentItem: Equatable {
    enum Role: Equatable {
        case agent
        case helper
        case process(nested: Bool)
    }

    let id: SurfaceID
    let state: AttentionTone
    let summary: String
    let detail: String
    let message: String?
    var role = Role.agent
    var startedBy: String?
    var mark: String?
}

// The Agents list's own ordering, and the state a row speaks since its title never names it.
extension AttentionTone {
    // Blocked and done share a rank, so waiting agents queue by age alone.
    var rank: Int {
        switch self {
        case .blocked, .done: return 0
        case .working: return 1
        case .idle: return 2
        }
    }

    var accessibilityName: String {
        switch self {
        case .blocked: return "Waiting"
        case .done: return "Done"
        case .working: return "Working"
        case .idle: return "Idle"
        }
    }
}

extension SidebarAgentItem {
    var showsState: Bool {
        if case .process = role { return false }
        return true
    }
}

final class SidebarAgentRow: SidebarJumpRow {
    private let glyphSlot = NSView()
    private let dot = StateDot()
    private let spinner = Spinner()
    private var item: SidebarAgentItem?
    private lazy var heightPin = heightAnchor.constraint(equalToConstant: Self.height)

    static let height: CGFloat = ChromeMetrics.Height.xl
    private static let jumpHint = "Jump to agent"
    private static let processJumpHint = "Jump to process"
    private static let processSymbol = "terminal"
    private static let glyphSize = NSSize(width: 14, height: 16)

    init(onActivate: @escaping () -> Void) {
        super.init(tooltip: Self.jumpHint, onActivate: onActivate)

        spinner.role = \.working
        for glyph in [dot, spinner] {
            glyph.translatesAutoresizingMaskIntoConstraints = false
            glyphSlot.addSubview(glyph)
            glyph.trailingAnchor.constraint(equalTo: glyphSlot.trailingAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            heightPin,
            glyphSlot.widthAnchor.constraint(equalToConstant: Self.glyphSize.width),
            glyphSlot.heightAnchor.constraint(equalToConstant: Self.glyphSize.height),
        ])
        accessories = [glyphSlot]
        centerOnTitleLine([dot, spinner])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func render(_ item: SidebarAgentItem) {
        guard item != self.item else { return }
        self.item = item
        rendersForTesting += 1
        heightPin.constant = item.role == .agent ? Self.height : ChromeMetrics.Height.control
        renderContent(item)
        let startedBy = item.startedBy.map { "Started by \($0)" }
        let notes = [startedBy, item.message].compactMap { $0 }
        tooltip?.label = notes.isEmpty ? Self.hint(for: item.role) : notes.joined(separator: "\n")
        tooltip?.style = item.message == nil ? .line : .paragraph
        tooltip?.relabel(from: self)
        announce(item)
        let speaks = [item.showsState ? item.state.accessibilityName : nil, item.detail, startedBy]
        setAccessibilityValue(speaks.compactMap { $0 }.joined(separator: ", "))
        dot.state = item.state.dot
        spinner.isHidden = item.state != .working
        spinner.isSpinning = item.state == .working
    }

    private func renderContent(_ item: SidebarAgentItem) {
        glyphSlot.isHidden = !item.showsState
        switch item.role {
        case .agent:
            render(
                Content(
                    title: item.summary, subtitle: item.detail, leading: .symbol(item.mark ?? Self.processSymbol),
                    leadingOnTitleLine: true))
        case .helper:
            render(
                Content(
                    title: item.summary, leading: .symbol(item.mark ?? Self.processSymbol), ink: .subtle, nests: true))
        case .process(let nested):
            render(Content(title: item.summary, leading: .symbol(Self.processSymbol), ink: .subtle, nests: nested))
        }
    }

    private static func hint(for role: SidebarAgentItem.Role) -> String {
        if case .process = role { return processJumpHint }
        return jumpHint
    }

    var itemForTesting: SidebarAgentItem? { item }

    private(set) var rendersForTesting = 0

    var dotForTesting: StateDot { dot }

    var isSpinningForTesting: Bool { !spinner.isHidden && spinner.isSpinning }

    var summaryTextForTesting: String { content.title }

    var isNestedForTesting: Bool { content.nests }

    var leadingSymbolForTesting: String? {
        guard case .symbol(let name) = content.leading else { return nil }
        return name
    }

    var showsStateForTesting: Bool { !glyphSlot.isHidden }

    var tooltipForTesting: String? { tooltip?.label }

    override func reapplyTheme() {
        if let item {
            renderContent(item)
            announce(item)
        }
        super.reapplyTheme()
    }

    // `render` labels the row with its title, the summary, which cuts a multi-sentence message short.
    private func announce(_ item: SidebarAgentItem) {
        setAccessibilityLabel(item.message.map { "\(item.summary), \($0)" } ?? item.summary)
    }
}
