import AppLog
import Foundation

// Narrower than `SurfaceAttention`: a rule never reports a completion.
enum AgentSignalState {
    case idle, working, blocked
}

enum RuleRegion {
    case oscTitle, oscProgress
}

indirect enum RuleMatcher {
    case contains(String)
    case regex(String)
    case any([RuleMatcher])
}

struct AgentStateRule {
    let id: String
    let state: AgentSignalState
    let priority: Int
    let region: RuleRegion
    let match: RuleMatcher
}

extension RuleMatcher {
    func matches(_ text: String) -> Bool {
        switch self {
        case .contains(let needle):
            return text.range(of: needle, options: .caseInsensitive) != nil
        case .regex(let pattern):
            return RulePatterns.matches(pattern, text)
        case .any(let matchers):
            return matchers.contains { $0.matches(text) }
        }
    }
}

// Codex pushes ~10 title events a second, so a pattern compiles once for the life of the process.
enum RulePatterns {
    private static var compiled: [String: Regex<AnyRegexOutput>] = [:]

    static func matches(_ pattern: String, _ text: String) -> Bool {
        guard let regex = regex(for: pattern) else { return false }
        return text.firstMatch(of: regex) != nil
    }

    private static func regex(for pattern: String) -> Regex<AnyRegexOutput>? {
        if let cached = compiled[pattern] { return cached }
        guard let built = try? Regex(pattern) else {
            Log.warning("AgentStateRule: `\(pattern)` is not a valid pattern, rule ignored", category: .workspace)
            return nil
        }
        compiled[pattern] = built
        return built
    }
}
