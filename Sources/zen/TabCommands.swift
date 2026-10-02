import ArgumentParser
import ControlProtocol

struct TabCommands: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tab", abstract: "Open, select, rename and close tabs.",
        subcommands: [New.self, Select.self, Rename.self, Close.self])

    struct New: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Open a tab behind the one showing, and print its address and pane as JSON.")

        @OptionGroup var connection: ConnectionOptions

        @Option(help: "A folder, ssh:<host>, or a title. This pane's workspace by default.")
        var workspace: String?

        @Option(help: "The folder it starts in. This pane's folder by default.")
        var cwd: String?

        @Option(help: "A command to run in it.")
        var cmd: String?

        @Flag(help: "Show it.")
        var focus = false

        func run() throws {
            let args = ControlArgs(
                workspace: workspace.map(CommandPath.workspace), cwd: try cwd.map(CommandPath.folder), cmd: cmd,
                focus: focus)
            let opened = try connection.client().send(.tabNew, args, expecting: TabResult.self)
            print(try JSONOutput.text(opened))
        }
    }

    struct Select: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show a tab.")

        @OptionGroup var connection: ConnectionOptions

        @Argument(help: "A tab address like w1.t3. This pane's tab by default.")
        var tab: String?

        func run() throws {
            _ = try connection.client().send(.tabSelect, ControlArgs(tab: tab), expecting: NoPayload.self)
        }
    }

    struct Rename: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Rename a tab. An empty title clears it.")

        @OptionGroup var connection: ConnectionOptions

        @Argument(help: "The new title.")
        var title: String

        @Option(help: "A tab address like w1.t3. This pane's tab by default.")
        var tab: String?

        func run() throws {
            let args = ControlArgs(tab: tab, title: title)
            _ = try connection.client().send(.tabRename, args, expecting: NoPayload.self)
        }
    }

    struct Close: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Close a tab. Refuses when something in it is running, or it is the window's last.")

        @OptionGroup var connection: ConnectionOptions

        @Argument(help: "A tab address like w1.t3. This pane's tab by default.")
        var tab: String?

        @Flag(help: "Close it anyway.")
        var force = false

        func run() throws {
            let args = ControlArgs(tab: tab, force: force)
            _ = try connection.client().send(.tabClose, args, expecting: NoPayload.self)
        }
    }
}
