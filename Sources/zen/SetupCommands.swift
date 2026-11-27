import AgentSetup
import ArgumentParser
import Foundation

struct SetupCommands: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "setup", abstract: "Teach a coding agent to use zen.",
        subcommands: [Claude.self, PiCommand.self])

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

    struct PiCommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "pi",
            abstract: "Install or update the zen skill and extension for Pi, and print what changed.",
            discussion: """
                Writes skills/zen/SKILL.md and extensions/zenterm-context.ts in $PI_CODING_AGENT_DIR, or ~/.pi/agent when it is unset. Pi discovers both files automatically. This command replaces them without asking.
                """)

        @Flag(help: "Remove what setup installed instead.")
        var remove = false

        func run() throws {
            let lines = try changes(
                environment: ProcessInfo.processInfo.environment, files: PiSetupFiles.bundled())
            lines.forEach { print($0) }
        }

        func changes(environment: [String: String], files: PiSetupFiles?) throws(ZenFailure) -> [String] {
            guard let files else {
                throw .app(
                    "zen can't find the Pi skill it ships with. Run the zen inside ZenTerm, at "
                        + "ZenTerm.app/Contents/MacOS/zen.")
            }
            let setup = PiSetup(configRoot: PiSetup.configRoot(environment: environment), files: files)
            do {
                if remove {
                    let removed = try setup.remove()
                    return removed.isEmpty ? ["Nothing to remove: zen isn't set up for Pi."] : removed
                }
                let changed = try setup.install()
                return changed.isEmpty ? ["Nothing to change: zen is set up for Pi."] : changed
            } catch {
                throw .app(error.message)
            }
        }
    }
}
