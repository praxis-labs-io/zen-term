import Foundation
import TerminalKit

enum AgentStateEngine {
    enum Outcome: Equatable {
        case matched(AgentSignalState, ruleID: String)
        // Distinct from a matched idle: only an idle nothing explains is held against a dropped spinner frame.
        case fallback
    }

    // A program's own status report outranks every rule: it is what the program says, not a reading of its screen.
    static func evaluate(
        _ rules: [AgentStateRule], title: String, progress: String, status: TerminalProgramStatus? = nil
    ) -> Outcome {
        if let status { return .matched(state(of: status.state), ruleID: "program_status") }
        var winner: AgentStateRule?
        for rule in rules where rule.match.matches(region(rule.region, title: title, progress: progress)) {
            if let current = winner, current.priority >= rule.priority { continue }
            winner = rule
        }
        guard let winner else { return .fallback }
        return .matched(winner.state, ruleID: winner.id)
    }

    // `done` is a finished turn, and an agent that failed has stopped and needs you as much as one asking.
    private static func state(of reported: TerminalProgramStatus.State) -> AgentSignalState {
        switch reported {
        case .idle, .done: return .idle
        case .working: return .working
        case .blocked, .failed: return .blocked
        }
    }

    private static func region(_ region: RuleRegion, title: String, progress: String) -> String {
        switch region {
        case .oscTitle: return title
        case .oscProgress: return progress
        }
    }
}

extension AgentStateEngine.Outcome {
    // A state we cannot explain is `idle`, never `blocked`: a false alarm costs more than a quiet row.
    var state: AgentSignalState {
        switch self {
        case .matched(let state, _): return state
        case .fallback: return .idle
        }
    }

    var label: String {
        switch self {
        case .matched(let state, let id): return "\(state) by \(id)"
        case .fallback: return "idle by fallback"
        }
    }
}
