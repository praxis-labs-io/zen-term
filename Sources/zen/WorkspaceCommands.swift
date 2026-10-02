import ArgumentParser
import ControlProtocol

struct WorkspaceCommands: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "workspace", abstract: "Open, switch to and close workspaces.",
        subcommands: [Open.self, New.self, Switch.self, Close.self])

    struct Open: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Open a workspace by folder or title, or find the one already open, and print it as JSON.")

        @OptionGroup var connection: ConnectionOptions

        @Argument(help: "A folder (starting with /, ~ or .), ssh:<host>, or a title.")
        var workspace: String

        @Flag(help: "Switch to it.")
        var focus = false

        func run() throws {
            let args = ControlArgs(workspace: CommandPath.workspace(workspace), focus: focus)
            let opened = try connection.client().send(.workspaceOpen, args, expecting: WorkspaceResult.self)
            print(try JSONOutput.text(opened))
        }
    }

    struct New: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Open a workspace with no config entry and print it as JSON.")

        @OptionGroup var connection: ConnectionOptions

        @Argument(help: "Its folder. The home folder by default.")
        var path: String?

        @Flag(help: "Switch to it.")
        var focus = false

        func run() throws {
            let args = ControlArgs(path: try path.map(CommandPath.folder), focus: focus)
            let made = try connection.client().send(.workspaceNew, args, expecting: WorkspaceResult.self)
            print(try JSONOutput.text(made))
        }
    }

    struct Switch: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Switch to a workspace.")

        @OptionGroup var connection: ConnectionOptions

        @Argument(help: "A folder, ssh:<host>, or a title. This pane's workspace by default.")
        var workspace: String?

        func run() throws {
            let args = ControlArgs(workspace: workspace.map(CommandPath.workspace))
            _ = try connection.client().send(.workspaceSwitch, args, expecting: NoPayload.self)
        }
    }

    struct Close: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Close a workspace. Refuses when something in it is running, or it is the window's last.")

        @OptionGroup var connection: ConnectionOptions

        @Argument(help: "A folder, ssh:<host>, or a title. This pane's workspace by default.")
        var workspace: String?

        @Flag(help: "Close it anyway.")
        var force = false

        func run() throws {
            let args = ControlArgs(workspace: workspace.map(CommandPath.workspace), force: force)
            _ = try connection.client().send(.workspaceClose, args, expecting: NoPayload.self)
        }
    }
}
