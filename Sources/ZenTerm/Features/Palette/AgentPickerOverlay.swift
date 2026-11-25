import AppKit

// The sidebar's Agents list as a palette panel, grouped under each row's place.
final class AgentPickerOverlay: PaletteOverlay {
    private enum Row {
        case header(SidebarAgentItem.Place)
        case agent(SidebarAgentItem)
    }

    static let returnAction = "Focus"

    private let onFocus: (SurfaceID) -> Void
    private var items: [SidebarAgentItem]
    private var rows: [Row] = []

    init(
        items: [SidebarAgentItem], onFocus: @escaping (SurfaceID) -> Void, onDismiss: @escaping () -> Void
    ) {
        self.items = items
        self.onFocus = onFocus
        super.init(placeholder: "Search agents", emptyText: "No matching agents", onDismiss: onDismiss)
        applyFilter(query: "")
        refreshRows()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(_ next: [SidebarAgentItem]) {
        guard next != items else { return }
        let held = rows.indices.contains(selected) ? rowIdentity(at: selected) : nil
        let heldIndex = selected
        items = next
        applyFilter(query: currentQuery)
        refreshRows()
        let byID = Dictionary(next.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for view in rowViews {
            guard let row = view as? AgentRowView, let item = byID[row.surface] else { continue }
            row.render(item)
        }
        reselect(byIdentity: held, near: heldIndex)
    }

    override func numberOfRows() -> Int { rows.count }

    override func makeRow(at index: Int) -> PaletteRowView {
        switch rows[index] {
        case .header(let place): return PaletteSectionHeader(title: place.name)
        case .agent(let item): return AgentRowView(item)
        }
    }

    override func rowIdentity(at index: Int) -> AnyHashable? {
        switch rows[index] {
        case .header(let place): return ["header", place.name, String(place.order)]
        case .agent(let item): return item.id
        }
    }

    override func isSelectable(at index: Int) -> Bool {
        if case .agent = rows[index] { return true }
        return false
    }

    override func returnAction(at index: Int) -> String? { Self.returnAction }

    override func applyFilter(query: String) {
        let q = query.trimmingCharacters(in: .whitespaces)
        let families = Self.families(of: items).compactMap { family -> [SidebarAgentItem]? in
            guard !q.isEmpty else { return family }
            let kept = family.enumerated().filter { $0.offset == 0 || Self.matches(q, $0.element) }.map(\.element)
            return kept.count > 1 || Self.matches(q, family[0]) ? kept : nil
        }
        rows = Self.grouped(families)
    }

    override func activate(index: Int, modifiers: NSEvent.ModifierFlags) {
        guard rows.indices.contains(index), case .agent(let item) = rows[index] else { return }
        onFocus(item.id)
    }

    private static func matches(_ query: String, _ item: SidebarAgentItem) -> Bool {
        [item.summary, item.agentLabel ?? item.process.name, item.place.name].contains {
            FuzzyMatch.score(query, $0) != nil
        }
    }

    private static func families(of items: [SidebarAgentItem]) -> [[SidebarAgentItem]] {
        var families: [[SidebarAgentItem]] = []
        for item in items {
            if item.role == .agent || families.isEmpty {
                families.append([item])
            } else {
                families[families.count - 1].append(item)
            }
        }
        return families
    }

    // Places in sidebar order; within one, the Agents list's own order.
    private static func grouped(_ families: [[SidebarAgentItem]]) -> [Row] {
        var places: [SidebarAgentItem.Place] = []
        var members: [SidebarAgentItem.Place: [SidebarAgentItem]] = [:]
        for family in families {
            let place = family[0].place
            if members[place] == nil { places.append(place) }
            members[place, default: []] += family
        }
        let ordered = places.enumerated().sorted { a, b in
            a.element.order != b.element.order ? a.element.order < b.element.order : a.offset < b.offset
        }
        return ordered.flatMap { place in
            [Row.header(place.element)] + (members[place.element] ?? []).map(Row.agent)
        }
    }

    var rowsForTesting: [String] {
        rows.map {
            switch $0 {
            case .header(let place): return "# \(place.name)"
            case .agent(let item): return item.role == .agent ? item.summary : "  \(item.summary)"
            }
        }
    }

    final class AgentRowView: SelectableRowView {
        private let stateGlyph = AgentStateGlyph()
        private(set) var item: SidebarAgentItem
        var surface: SurfaceID { item.id }

        init(_ item: SidebarAgentItem) {
            self.item = item
            super.init(Self.content(item))
            accessories = [detailLabel, stateGlyph]
            centerOnTitleLine(stateGlyph.marks)
            apply(item)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        func render(_ next: SidebarAgentItem) {
            guard next != item else { return }
            item = next
            render(Self.content(next))
            apply(next)
        }

        private func apply(_ item: SidebarAgentItem) {
            detail = item.agentLabel ?? ""
            stateGlyph.isHidden = !item.showsState
            stateGlyph.show(item.state)
            setAccessibilityLabel(item.message.map { "\(item.summary), \($0)" } ?? item.summary)
            let speaks = [item.showsState ? item.state.accessibilityName : nil, item.agentLabel, item.place.name]
            setAccessibilityValue(speaks.compactMap { $0 }.joined(separator: ", "))
        }

        private static func content(_ item: SidebarAgentItem) -> Content {
            switch item.role {
            case .agent: return Content(title: item.summary, leading: .process(item.process))
            case .helper, .process:
                return Content(
                    title: item.summary, leading: .process(item.process), ink: .subtle, nesting: .underTitle)
            }
        }

        override func reapplyTheme() {
            render(Self.content(item))
            apply(item)
            super.reapplyTheme()
        }

        var leadingProcessForTesting: ProcessIcon? {
            guard case .process(let process) = content.leading else { return nil }
            return process
        }

        var isNestedForTesting: Bool { content.nests }

        var showsStateForTesting: Bool { !stateGlyph.isHidden }

        var stateForTesting: StateDot.State? { stateGlyph.dot.state }

        var isSpinningForTesting: Bool { stateGlyph.isSpinning }
    }
}
