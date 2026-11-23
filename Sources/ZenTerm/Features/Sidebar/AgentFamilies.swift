import Foundation

// The Agents list's order: each agent, then every pane under it, most urgent family first.
enum AgentFamilies {
    struct Member {
        var item: SidebarAgentItem
        let since: Date?
        let position: [Int]
        let token: Int?
        let parent: Int?
        let isAgent: Bool
    }

    // `parents` holds every live pane's parent, rows or not, so ownership passes through any pane.
    static func arrange(_ members: [Member], parents: [Int: Int]) -> [SidebarAgentItem] {
        let agentsByToken = Dictionary(
            members.filter(\.isAgent).compactMap { member in member.token.map { ($0, member) } },
            uniquingKeysWith: { first, _ in first })
        var starters: [SurfaceID: Member] = [:]
        var heads: [SurfaceID: SurfaceID] = [:]
        for member in members {
            guard let lineage = startingAgents(of: member, in: agentsByToken, parents: parents), let head = lineage.last
            else {
                continue
            }
            starters[member.item.id] = lineage[0]
            heads[member.item.id] = head.item.id
        }
        heads = heads.filter { heads[$0.value] == nil }
        let byHead = Dictionary(grouping: members.compactMap { member in heads[member.item.id].map { ($0, member) } }) {
            $0.0
        }.mapValues { $0.map(\.1) }
        let families = members.filter { $0.isAgent && heads[$0.item.id] == nil }.map { head in
            [head] + (byHead[head.item.id] ?? []).sorted { $0.position.lexicographicallyPrecedes($1.position) }
        }
        return families.sorted(by: precedes).flatMap { family in
            family.map { member in
                var item = member.item
                let nested = heads[item.id] != nil
                item.role = member.isAgent ? (nested ? .helper : .agent) : .process(nested: nested)
                if let starter = starters[item.id], nested, starter.item.id != heads[item.id] {
                    item.startedBy = starter.item.summary
                }
                return item
            }
        }
    }

    private static func startingAgents(of member: Member, in agents: [Int: Member], parents: [Int: Int]) -> [Member]? {
        var lineage: [Member] = []
        var seen = Set(member.token.map { [$0] } ?? [])
        var next = member.parent
        while let token = next, seen.insert(token).inserted {
            if let agent = agents[token] { lineage.append(agent) }
            next = parents[token]
        }
        if next != nil, next == member.token { return nil }
        return lineage.isEmpty ? nil : lineage
    }

    private static func precedes(_ a: [Member], _ b: [Member]) -> Bool {
        let (rankA, sinceA) = urgency(a)
        let (rankB, sinceB) = urgency(b)
        if rankA != rankB { return rankA < rankB }
        if rankA == AttentionTone.blocked.rank, sinceA != sinceB {
            return (sinceA ?? .distantFuture) < (sinceB ?? .distantFuture)
        }
        return a[0].position.lexicographicallyPrecedes(b[0].position)
    }

    private static func urgency(_ family: [Member]) -> (rank: Int, since: Date?) {
        let rank = family.map(\.item.state.rank).min() ?? AttentionTone.idle.rank
        let since = family.filter { $0.item.state.rank == rank && $0.item.state.isWaiting }.compactMap(\.since).min()
        return (rank, since)
    }
}
