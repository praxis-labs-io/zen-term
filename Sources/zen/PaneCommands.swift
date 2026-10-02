import ArgumentParser
import ControlProtocol

struct PaneCommands: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pane", abstract: "Split, focus, close, type into and read panes.",
        subcommands: [Split.self, Focus.self, Close.self, Send.self, Read.self])

    struct Split: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Open a pane beside one, leaving focus where it is, and print its token as JSON.")

        @OptionGroup var connection: ConnectionOptions

        @Option(help: "The pane to split. This pane by default.")
        var pane: Int?

        @Option(help: "Where the new pane goes: right or down.")
        var dir: PaneDirection = .right

        @Option(help: "A command to run in it.")
        var cmd: String?

        @Flag(help: "Focus it.")
        var focus = false

        func run() throws {
            let args = ControlArgs(cmd: cmd, focus: focus, pane: pane, dir: dir)
            let opened = try connection.client().send(.paneSplit, args, expecting: PaneResult.self)
            print(try JSONOutput.text(opened))
        }
    }

    struct Focus: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show a pane's tab and focus the pane.")

        @OptionGroup var connection: ConnectionOptions

        @Argument(help: "A pane or drawer token.")
        var pane: Int

        func run() throws {
            _ = try connection.client().send(.paneFocus, ControlArgs(pane: pane), expecting: NoPayload.self)
        }
    }

    struct Close: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Close a pane. Refuses when it is running something. The last pane closes its tab.")

        @OptionGroup var connection: ConnectionOptions

        @Argument(help: "A pane token.")
        var pane: Int

        @Flag(help: "Close it anyway.")
        var force = false

        func run() throws {
            let args = ControlArgs(force: force, pane: pane)
            _ = try connection.client().send(.paneClose, args, expecting: NoPayload.self)
        }
    }

    struct Send: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Paste text into a pane. Control characters arrive as spaces.")

        @OptionGroup var connection: ConnectionOptions

        @Argument(help: "The text. Several lines arrive as one block.")
        var text: String

        @Option(help: "A pane or drawer token. This pane by default.")
        var pane: Int?

        @Flag(help: "Press Return after it, which runs the block once.")
        var enter = false

        func run() throws {
            let args = ControlArgs(pane: pane, text: text, enter: enter)
            _ = try connection.client().send(.paneSend, args, expecting: NoPayload.self)
        }
    }

    struct Read: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Print a pane's text: the rows on screen, or its last lines with --lines.")

        @OptionGroup var connection: ConnectionOptions

        @Option(help: "A pane or drawer token. This pane by default.")
        var pane: Int?

        @Option(help: "Print the last this many lines, scrollback included.")
        var lines: Int?

        func validate() throws {
            if let lines, lines < 1 { throw ValidationError("--lines must be 1 or more.") }
        }

        func run() throws {
            let args = ControlArgs(pane: pane, lines: lines)
            print(try connection.client().send(.paneRead, args, expecting: PaneText.self).text)
        }
    }
}

extension PaneDirection: ExpressibleByArgument {}
