import AgentSetup
import ArgumentParser
import Foundation

struct SetupCommands: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "setup", abstract: "Teach a coding agent to use zen.",
        subcommands: [Claude.self, Codex.self])

    struct Codex: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Install or update the zen skill and session hook for Codex.",
            discussion: "After setup, open /hooks in Codex to review and trust the ZenTerm hook.")

        @Flag(help: "Remove what setup installed instead.")
        var remove = false

        func run() throws {
            let lines = try SetupCommands.apply(
                client: .codex, remove: remove,
                environment: ProcessInfo.processInfo.environment, files: ClaudeSetupFiles.bundled())
            lines.forEach { print($0) }
        }
    }

    struct Claude: ParsableCommand {
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

        func run() throws {
            let lines = try changes(
                environment: ProcessInfo.processInfo.environment, files: ClaudeSetupFiles.bundled())
            lines.forEach { print($0) }
        }

        func changes(environment: [String: String], files: ClaudeSetupFiles?) throws(ZenFailure) -> [String] {
            try SetupCommands.apply(client: .claude, remove: remove, environment: environment, files: files)
        }
    }

    private static func apply(
        client: ClaudeSetup.Client, remove: Bool, environment: [String: String], files: ClaudeSetupFiles?
    ) throws(ZenFailure) -> [String] {
        guard let files else {
            throw .app(
                "zen can't find the skill it ships with. Run the zen inside ZenTerm, at "
                    + "ZenTerm.app/Contents/MacOS/zen.")
        }
        let setup = client.setup(files: files, environment: environment)
        do {
            if remove {
                let removed = try setup.remove()
                return removed.isEmpty ? ["Nothing to remove: zen isn't set up for \(client.displayName)."] : removed
            }
            let changed = try setup.install()
            if client == .codex, !changed.isEmpty {
                return changed + [
                    "Open /hooks in Codex to review and trust the ZenTerm hook, then start a new session."
                ]
            }
            return changed.isEmpty ? ["Nothing to change: zen is set up for \(client.displayName)."] : changed
        } catch {
            throw .app(error.message)
        }
    }
}
