import ArgumentParser
import ControlProtocol
import Foundation

struct WorktreeCommands: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "worktree", abstract: "List, create and remove a workspace's worktrees.",
        subcommands: [List.self, Create.self, Remove.self])

    // A create copies the carry and a remove deletes a folder, either of which outlasts the usual wait on a big checkout.
    static let gitReplyTimeout: time_t = 300

    enum Base: String, ExpressibleByArgument, CaseIterable {
        case defaultBranch = "default"
        case current
    }

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Print the worktrees of a workspace's repo as JSON.")

        @OptionGroup var connection: ConnectionOptions

        @Option(help: "A folder, ssh:<host>, or a title. This pane's workspace by default.")
        var workspace: String?

        func run() throws {
            let args = ControlArgs(workspace: workspace.map(CommandPath.workspace))
            let listed = try connection.client().send(.worktreeList, args, expecting: WorktreeListResult.self)
            print(try JSONOutput.text(listed))
        }
    }

    struct Create: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract:
                "Make a worktree, copy what the workspace carries into it, open it behind the view, and print it as JSON."
        )

        @OptionGroup var connection: ConnectionOptions

        @Argument(help: "The branch to make, or with --existing the branch to check out.")
        var branch: String

        @Option(help: "A folder, ssh:<host>, or a title. This pane's workspace by default.")
        var workspace: String?

        @Option(help: "Where a new branch starts: the default branch, or what the workspace's checkout is on.")
        var base: Base?

        @Flag(help: "Check out a branch that already exists.")
        var existing = false

        @Flag(help: "Switch to it.")
        var focus = false

        func validate() throws {
            if existing, base != nil { throw ValidationError("--base only applies to a new branch, not --existing.") }
        }

        func run() throws {
            let args = ControlArgs(
                workspace: workspace.map(CommandPath.workspace), focus: focus, branch: branch,
                base: (base ?? .defaultBranch).rawValue, existing: existing)
            var client = try connection.client()
            client.replyTimeout = WorktreeCommands.gitReplyTimeout
            print(try JSONOutput.text(client.send(.worktreeCreate, args, expecting: WorktreeResult.self)))
        }
    }

    struct Remove: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract:
                "Remove a worktree and close its tabs. Refuses when it holds uncommitted files or commits no branch has."
        )

        @OptionGroup var connection: ConnectionOptions

        @Argument(help: "Its folder (starting with /, ~ or .) or its branch.")
        var worktree: String

        @Option(help: "A folder, ssh:<host>, or a title. This pane's workspace by default.")
        var workspace: String?

        @Flag(help: "Remove it anyway.")
        var force = false

        func run() throws {
            var client = try connection.client()
            client.replyTimeout = WorktreeCommands.gitReplyTimeout
            _ = try client.send(
                .worktreeRemove, args(in: FileManager.default.currentDirectoryPath), expecting: NoPayload.self)
        }

        func args(in cwd: String) -> ControlArgs {
            var args = ControlArgs(workspace: workspace.map { CommandPath.workspace($0, in: cwd) }, force: force)
            if CommandPath.looksLikePath(worktree) {
                args.path = CommandPath.absolute(worktree, in: cwd)
            } else {
                args.branch = worktree
            }
            return args
        }
    }
}
