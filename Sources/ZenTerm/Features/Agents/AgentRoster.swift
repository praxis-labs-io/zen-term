import Foundation

// Which surfaces in one window run an agent, which agent, and what it last said. Main-thread only.
final class AgentRoster {
    enum Source: Int, Comparable {
        case signal, launch

        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    struct Agent: Equatable {
        var name: String?
        var source: Source
        var message: String?
        var hasExited = false
    }

    static let knownAgents: Set<String> = ["claude", "codex"]

    static let unnamed = "agent"

    private(set) var agents: [SurfaceID: Agent] = [:]
    private var busy = BusyFallWatch()

    static func agentName(launching command: String, listed: [String]) -> String? {
        guard let program = program(of: command) else { return nil }
        let name = program.lowercased()
        return knownAgents.contains(name) || listed.contains(name) ? program : nil
    }

    // A whole token, so `pi` is not found inside "pipeline" and `gemini-cli` is found whole.
    static func agentName(notifying title: String, listed: [String]) -> String? {
        let words = Set(
            title.lowercased().split { !$0.isLetter && !$0.isNumber && !programPunctuation.contains($0) }
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: String(programPunctuation))) })
        let candidates = knownAgents.sorted() + listed
        return candidates.first { words.contains($0.lowercased()) }
    }

    private static let programPunctuation: Set<Character> = ["-", "_", "."]

    static func program(of command: String) -> String? {
        command.split(whereSeparator: \.isWhitespace).first.map { URL(fileURLWithPath: String($0)).lastPathComponent }
    }

    func contains(_ id: SurfaceID) -> Bool { agents[id] != nil }

    func identify(_ id: SurfaceID, name: String?, source: Source) {
        guard var agent = agents[id] else {
            agents[id] = Agent(name: name, source: source)
            return
        }
        guard name != nil, agent.name == nil || source > agent.source else { return }
        agent.name = name
        agent.source = source
        agents[id] = agent
    }

    func setMessage(_ id: SurfaceID, _ message: String?) {
        agents[id]?.message = message
    }

    func markExited(_ id: SurfaceID, message: String) {
        guard agents[id] != nil else { return }
        agents[id]?.hasExited = true
        agents[id]?.message = message
    }

    func trackBusy(_ id: SurfaceID, _ isBusy: Bool) {
        guard agents[id] != nil, busy.fell(id, isBusy: isBusy) else { return }
        agents[id]?.hasExited = true
    }

    func drop(_ id: SurfaceID) {
        agents[id] = nil
        busy.forget(id)
    }
}
