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
        var failed = false
        var hasExited = false
    }

    static let knownAgents: Set<String> = ["claude", "codex"]

    static let unnamed = "agent"

    private(set) var agents: [SurfaceID: Agent] = [:]
    private var busy: Set<SurfaceID> = []

    static func agentName(launching command: String, ai: String?) -> String? {
        guard let program = program(of: command) else { return nil }
        let configured = ai.flatMap(Self.program(of:))
        return program == configured || knownAgents.contains(program) ? program : nil
    }

    // A whole word, so a short program name like `pi` is not found inside "pipeline".
    static func agentName(notifying title: String, ai: String?) -> String? {
        let words = Set(title.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
        let candidates = knownAgents.sorted() + [ai.flatMap(Self.program(of:))].compactMap { $0 }
        return candidates.first { words.contains($0.lowercased()) }
    }

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

    func markExited(_ id: SurfaceID, failed: Bool, message: String) {
        guard agents[id] != nil else { return }
        agents[id]?.hasExited = true
        agents[id]?.failed = failed
        agents[id]?.message = message
    }

    // Only a fall counts as an exit: a surface polled before its program starts has not been busy yet.
    func trackBusy(_ id: SurfaceID, _ isBusy: Bool) {
        guard agents[id] != nil else { return }
        if isBusy {
            busy.insert(id)
        } else if busy.remove(id) != nil {
            agents[id]?.hasExited = true
        }
    }

    func drop(_ id: SurfaceID) {
        agents[id] = nil
        busy.remove(id)
    }
}
