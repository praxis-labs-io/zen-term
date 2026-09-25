import Foundation
import TerminalKit

enum AgentRules {
    static func rules(for agentName: String?) -> [AgentStateRule] {
        key(for: agentName) == "codex" ? codex : progressOnly
    }

    // A launch names an agent by its program (`claude`), a notification by its own words (`Claude Code`).
    static func key(for agentName: String?) -> String? {
        guard let name = agentName?.lowercased(), !name.isEmpty else { return nil }
        return AgentRoster.knownAgents.first { name.contains($0) }
    }

    static func agentName(matching title: String) -> String? {
        identifiers.first { $0.match.matches(title) }?.name
    }

    // A leading braille frame is far narrower in a title than on screen, where any build tool draws one.
    private static let identifiers: [(name: String, match: RuleMatcher)] = [
        (
            "codex",
            .any([
                .regex("^codex$"),
                .regex(codexPrompt),
                .regex("^[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏] "),
            ])
        )
    ]

    // The prompt blinks between `[ ! ]` and `[ . ]`, and a task's own words can say "Action Required".
    private static let codexPrompt = #"^\[ [!.] \] Action Required"#

    static let clearedProgress = "4;0"

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
            match: .regex(codexPrompt)),
        AgentStateRule(
            id: "codex_title_working", state: .working, priority: 1_050, region: .oscTitle,
            match: .regex("(?:^| )[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏](?: |$)")),
    ]

    // Claude's title flickers to idle mid-turn while progress holds working, so progress is the only state it gives.
    private static let progressOnly: [AgentStateRule] = [
        AgentStateRule(
            id: "progress_working", state: .working, priority: 1_100, region: .oscProgress,
            match: .regex("^4;3")),
        AgentStateRule(
            id: "progress_idle", state: .idle, priority: 250, region: .oscProgress,
            match: .regex("^4;0")),
    ]

    // Claude's title tail is the live tool name, which is the nearest it has to the prose Codex sends.
    static func message(fromTitle title: String, agentName: String?) -> String? {
        guard key(for: agentName) == "claude", let glyph = title.first, claudeWorkingGlyphs.contains(glyph)
        else { return nil }
        let trimmed = title.dropFirst().trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    // `✳` is left out: it heads the idle title Claude flickers to mid-turn, whose tail is only "Claude Code".
    private static let claudeWorkingGlyphs: Set<Character> = ["◐", "◑", "◒", "◓"]
}
