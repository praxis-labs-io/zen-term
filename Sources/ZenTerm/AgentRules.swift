import Foundation
import TerminalKit

/// The rules ZenTerm ships, per agent. Data, not configuration: an agent we have no rules for reads idle.
enum AgentRules {
    static func rules(for agentName: String?) -> [AgentStateRule] {
        key(for: agentName) == "codex" ? codex : progressOnly
    }

    /// A launch names an agent by its program (`claude`), a notification by its own words (`Claude Code`).
    static func key(for agentName: String?) -> String? {
        guard let name = agentName?.lowercased(), !name.isEmpty else { return nil }
        return AgentRoster.knownAgents.first { name.contains($0) }
    }

    /// The agent a title alone identifies, for a pane ZenTerm did not launch. Nil unless a pattern is sure.
    static func agentName(matching title: String) -> String? {
        identifiers.first { $0.match.matches(title) }?.name
    }

    // A leading braille frame is far narrower in a title than on screen, where any build tool draws one.
    private static let identifiers: [(name: String, match: RuleMatcher)] = [
        (
            "codex",
            .any([
                .regex("^codex$"),
                .contains("Action Required"),
                .regex("^[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏] "),
            ])
        )
    ]

    /// What the progress region reads before a program has reported anything.
    static let clearedProgress = "4;0"

    /// The OSC 9;4 payload the rules read, in the shape the sequence itself carries.
    static func progressRegion(_ progress: TerminalProgress?) -> String {
        guard let progress else { return clearedProgress }
        switch progress.state {
        case .running: return "4;1;\(Int(((progress.fraction ?? 0) * 100).rounded()))"
        case .error: return "4;2"
        case .indeterminate: return "4;3"
        case .paused: return "4;4"
        }
    }

    // Codex emits no OSC 9;4 at all, so its title is the whole signal.
    private static let codex: [AgentStateRule] = [
        AgentStateRule(
            id: "codex_title_blocked", state: .blocked, priority: 1_100, region: .oscTitle,
            // The blocked title alternates with `[ . ]` at 1 Hz, so match the phrase and never the whole string.
            match: .contains("Action Required")),
        AgentStateRule(
            id: "codex_title_working", state: .working, priority: 1_050, region: .oscTitle,
            match: .regex("(?:^| )[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏](?: |$)")),
    ]

    // What Claude runs on, and the reasonable floor for an agent we ship no rules for: any program that
    // reports OSC 9;4 gets working and idle for free. Claude's title flickers to idle mid-turn for as long
    // as 20s while progress holds working, so it is read for the row's message and never for state.
    private static let progressOnly: [AgentStateRule] = [
        AgentStateRule(
            id: "progress_working", state: .working, priority: 1_100, region: .oscProgress,
            match: .regex("^4;3")),
        AgentStateRule(
            id: "progress_idle", state: .idle, priority: 250, region: .oscProgress,
            match: .regex("^4;0")),
    ]

    /// Claude's title tail is the live tool name, which is the nearest it has to the prose Codex sends.
    static func message(fromTitle title: String, agentName: String?) -> String? {
        guard key(for: agentName) == "claude" else { return nil }
        let tail = title.drop { spinnerGlyphs.contains($0) || $0.isWhitespace }
        let trimmed = tail.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static let spinnerGlyphs: Set<Character> = ["◐", "◑", "◒", "◓", "✳"]
}
