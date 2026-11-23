import AgentSetup
import ArgumentParser
import Foundation

struct SetupCommands: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "setup", abstract: "Teach a coding agent to use zen.",
        subcommands: [Claude.self])

    struct Claude: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Install or update the zen skill and session hook for Claude Code, and print what changed.",
            discussion: """
                Writes skills/zen/SKILL.md and hooks/zenterm-context.sh in $CLAUDE_CONFIG_DIR, or ~/.claude \
                when it is unset, and adds the hook under hooks.SessionStart in settings.json. Every other \
                entry in settings.json stays. Run it again after a ZenTerm update to refresh both.
                """)

        @Flag(help: "Remove what setup installed instead.")
        var remove = false

        func run() throws {
            let lines = try changes(
                environment: ProcessInfo.processInfo.environment, files: ClaudeSetupFiles.bundled())
            lines.forEach { print($0) }
        }

        func changes(environment: [String: String], files: ClaudeSetupFiles?) throws(ZenFailure) -> [String] {
            guard let files else {
                throw .app(
                    "zen can't find the skill it ships with. Run the zen inside ZenTerm, at "
                        + "ZenTerm.app/Contents/MacOS/zen.")
            }
            let setup = ClaudeSetup(configRoot: ClaudeSetup.configRoot(environment: environment), files: files)
            do {
                if remove {
                    let removed = try setup.remove()
                    return removed.isEmpty ? ["Nothing to remove: zen isn't set up for Claude Code."] : removed
                }
                let changed = try setup.install()
                return changed.isEmpty ? ["Nothing to change: zen is set up for Claude Code."] : changed
            } catch {
                throw .app(error.message)
            }
        }
    }
}
