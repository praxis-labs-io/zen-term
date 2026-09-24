import Foundation

/// Runs an agent's rules over one pushed signal. Pure: no clock, no state, no UI.
enum AgentStateEngine {
    enum Outcome: Equatable {
        case matched(AgentSignalState, ruleID: String)
        /// A screen that proves nothing. Hold whatever state was already published.
        case skip(ruleID: String)
        /// Nothing matched. Resolves to `idle`, and is its own case so a log line can say which happened.
        case fallback
    }

    static func evaluate(_ rules: [AgentStateRule], title: String, progress: String) -> Outcome {
        var winner: AgentStateRule?
        for rule in rules where rule.match.matches(region(rule.region, title: title, progress: progress)) {
            if let current = winner, current.priority >= rule.priority { continue }
            winner = rule
        }
        guard let winner else { return .fallback }
        return winner.skipStateUpdate ? .skip(ruleID: winner.id) : .matched(winner.state, ruleID: winner.id)
    }

    private static func region(_ region: RuleRegion, title: String, progress: String) -> String {
        switch region {
        case .oscTitle: return title
        case .oscProgress: return progress
        }
    }
}

extension AgentStateEngine.Outcome {
    /// A state we cannot explain is `idle`, never `blocked`: a false alarm costs more than a quiet row.
    var state: AgentSignalState? {
        switch self {
        case .matched(let state, _): return state
        case .fallback: return .idle
        case .skip: return nil
        }
    }

    var label: String {
        switch self {
        case .matched(let state, let id): return "\(state) by \(id)"
        case .skip(let id): return "held by \(id)"
        case .fallback: return "idle by fallback"
        }
    }
}
