import AgentSetup
import ArgumentParser
import Foundation

struct SetupCommands: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "setup", abstract: "Teach a coding agent to use zen.",
        subcommands: [Claude.self, Codex.self])

    struct Claude: AgentSetupCommand {
        typealias Installer = ClaudeSetup
        static let agentName = "Claude Code"

        static let configuration = CommandConfiguration(
            abstract: "Install or update the zen skill and session hook for Claude Code, and print what changed.",
            discussion: """
                Writes skills/zen/SKILL.md and hooks/zenterm-context.sh in $CLAUDE_CONFIG_DIR, or ~/.claude \
                when it is unset, and adds the hook under hooks.SessionStart in settings.json. Every other \
                entry in settings.json stays. ZenTerm updates both when Claude starts after an app update, \
                and asks first when either has edits. This command replaces them without asking.
                """)

        @Flag(help: "Remove what setup installed instead.")
        var remove = false
    }

    struct Codex: AgentSetupCommand {
        typealias Installer = CodexSetup
        static let agentName = "Codex"

        static let configuration = CommandConfiguration(
            abstract: "Install or update the zen skill and session hook for Codex, and print what changed.",
            discussion: """
                Writes skills/zen/SKILL.md and hooks/zenterm-context.sh in $CODEX_HOME, or ~/.codex when it \
                is unset, and adds the hook under hooks.SessionStart in hooks.json. Every other entry in \
                hooks.json stays. Codex asks you to trust the hook when it next starts. ZenTerm updates both \
                when Codex starts after an app update, and asks first when either has edits. This command \
                replaces them without asking.
                """)

        @Flag(help: "Remove what setup installed instead.")
        var remove = false
    }
}
