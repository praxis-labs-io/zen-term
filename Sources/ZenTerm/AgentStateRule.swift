import AppLog
import Foundation

/// What a rule proves about an agent. Narrower than `SurfaceAttention`: a rule never reports a completion.
enum AgentSignalState {
    case idle, working, blocked
}

/// Where a rule reads. Both are pushed by the program, so a match is always the live screen.
enum RuleRegion {
    case oscTitle, oscProgress
}

indirect enum RuleMatcher {
    case contains(String)
    case regex(String)
    /// Matches when any single line of the region matches.
    case lineRegex(String)
    case all([RuleMatcher])
    case any([RuleMatcher])
    case not([RuleMatcher])
}

struct AgentStateRule {
    let id: String
    let state: AgentSignalState
    let priority: Int
    let region: RuleRegion
    var skipStateUpdate = false
    let match: RuleMatcher
}

extension RuleMatcher {
    func matches(_ text: String) -> Bool {
        switch self {
        case .contains(let needle):
            return text.range(of: needle, options: .caseInsensitive) != nil
        case .regex(let pattern):
            return RulePatterns.matches(pattern, text)
        case .lineRegex(let pattern):
            return text.split(separator: "\n", omittingEmptySubsequences: false)
                .contains { RulePatterns.matches(pattern, String($0)) }
        case .all(let matchers):
            return matchers.allSatisfy { $0.matches(text) }
        case .any(let matchers):
            return matchers.contains { $0.matches(text) }
        case .not(let matchers):
            return !matchers.contains { $0.matches(text) }
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
            Log.warning("AgentStateRule: `\(pattern)` is not a valid pattern — rule ignored", category: .workspace)
            return nil
        }
        compiled[pattern] = built
        return built
    }
}
