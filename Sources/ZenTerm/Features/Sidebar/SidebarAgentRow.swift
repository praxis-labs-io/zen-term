import AppKit

struct SidebarAgentItem: Equatable {
    enum Role: Equatable {
        case agent
        case helper
        case process
    }

    // What the row's second line names: a workspace, or a tab-less float's title, in sidebar order.
    struct Place: Hashable {
        let name: String
        let order: Int
    }

    let id: SurfaceID
    let state: AttentionTone
    let summary: String
    let detail: String
    let message: String?
    var role = Role.agent
    var startedBy: String?
    var process = ProcessIcon.unknownAgent
    var canClose = false
    var place = Place(name: "", order: Int.max)
    // The agent's name where its chip is the robot, which cannot say which agent it is.
    var agentLabel: String?
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
    private let stateGlyph = AgentStateGlyph()
    private var item: SidebarAgentItem?
    private lazy var heightPin = heightAnchor.constraint(equalToConstant: Self.height)

    static let height: CGFloat = ChromeMetrics.Height.xl
    private static let jumpHint = "Jump to agent"
    private static let processJumpHint = "Jump to process"

    init(onActivate: @escaping () -> Void) {
        super.init(tooltip: Self.jumpHint, onActivate: onActivate)

        heightPin.isActive = true
        accessories = [stateGlyph]
        centerOnTitleLine(stateGlyph.marks)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func render(_ item: SidebarAgentItem) {
        guard item != self.item else { return }
        self.item = item
        rendersForTesting += 1
        renderContent(item)
        let startedBy = item.startedBy.map { "Started by \($0)" }
        let notes = [startedBy, item.message].compactMap { $0 }
        tooltip?.label = notes.isEmpty ? Self.hint(for: item.role) : notes.joined(separator: "\n")
        tooltip?.style = item.message == nil ? .line : .paragraph
        tooltip?.relabel(from: self)
        announce(item)
        let speaks = [
            Self.spokenProgram(item), item.showsState ? item.state.accessibilityName : nil, item.detail, startedBy,
        ]
        setAccessibilityValue(speaks.compactMap { $0 }.joined(separator: ", "))
        stateGlyph.show(item.state)
    }

    private func renderContent(_ item: SidebarAgentItem) {
        stateGlyph.isHidden = !item.showsState
        switch item.role {
        case .agent:
            render(
                Content(
                    title: item.summary, subtitle: item.detail, leading: .process(item.process),
                    leadingOnTitleLine: true, trimsSubtitleDescent: true))
        case .helper, .process:
            render(
                Content(title: item.summary, leading: .process(item.process), ink: .subtle, nesting: .underTitle))
        }
        pinHeight()
    }

    private func pinHeight() {
        heightPin.constant = item?.role == .agent ? Self.height - trimmedSubtitleDescent : ChromeMetrics.Height.control
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        pinHeight()
    }

    // The chip names the program only to the eye, since the row is the one accessibility element.
    private static func spokenProgram(_ item: SidebarAgentItem) -> String? {
        item.process == .unknownAgent || item.process.name == item.summary ? nil : item.process.name
    }

    private static func hint(for role: SidebarAgentItem.Role) -> String {
        if case .process = role { return processJumpHint }
        return jumpHint
    }

    var canClose: Bool { item?.canClose == true }

    var itemForTesting: SidebarAgentItem? { item }

    private(set) var rendersForTesting = 0

    var dotForTesting: StateDot { stateGlyph.dot }

    var isSpinningForTesting: Bool { stateGlyph.isSpinning }

    var summaryTextForTesting: String { content.title }

    var isNestedForTesting: Bool { content.nests }

    var leadingProcessForTesting: ProcessIcon? {
        guard case .process(let process) = content.leading else { return nil }
        return process
    }

    var showsStateForTesting: Bool { !stateGlyph.isHidden }

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
