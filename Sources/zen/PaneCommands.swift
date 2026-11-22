import ArgumentParser
import ControlProtocol
import Foundation

struct PaneCommands: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pane", abstract: "Run programs in, split, focus, close, type into and read panes.",
        subcommands: [Run.self, Split.self, Focus.self, Close.self, Send.self, Read.self])

    struct Run: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Run a program in a new pane, in a tab behind this one, and print the pane as JSON.",
            discussion: "The pane closes when the program exits, unless --keep. With --task, zen answers once "
                + "the task is sent, or says why it was not.")

        @OptionGroup var connection: ConnectionOptions

        @Option(help: "A name for the pane, unique among open panes. It works anywhere a pane token does.")
        var name: String?

        @Option(help: "A first message to send the program once it reports it is ready.")
        var task: String?

        @Option(help: "Split the pane instead of opening a tab: right or down.")
        var split: PaneDirection?

        @Option(help: "The pane to split, or whose workspace gets the tab. This pane by default.")
        var pane: ControlAddress.Pane?

        @Flag(help: "Show it.")
        var focus = false

        @Flag(help: "Keep the pane open after the program exits.")
        var keep = false

        @Flag(help: "Keep the pane open after this pane closes. Otherwise it closes with it.")
        var outliveParent = false

        @Argument(parsing: .captureForPassthrough, help: "The command to run, in a shell.")
        var command: [String] = []

        func validate() throws {
            if command.isEmpty { throw ValidationError("pane run needs a command to run.") }
            if let name, !ControlAddress.Pane.isValidName(name) {
                throw ValidationError("--name needs at least one character that is not a digit or a space.")
            }
        }

        func run() throws {
            let args = ControlArgs(
                cmd: command.joined(separator: " "), focus: focus, pane: pane, name: name, task: task, split: split,
                keep: keep, outliveParent: outliveParent)
            var client = try connection.client()
            client.replyTimeout = time_t(ControlWire.longestReplyWait)
            print(try JSONOutput.text(client.send(.paneRun, args, expecting: PaneRunResult.self)))
        }
    }

    struct Split: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Open a pane beside one, leaving focus where it is, and print its token as JSON.")

        @OptionGroup var connection: ConnectionOptions

        @Option(help: "The pane to split. This pane by default.")
        var pane: ControlAddress.Pane?

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

        @Argument(help: "A pane or drawer token, or a pane's name.")
        var pane: ControlAddress.Pane

        func run() throws {
            _ = try connection.client().send(.paneFocus, ControlArgs(pane: pane), expecting: NoPayload.self)
        }
    }

    struct Close: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Close a pane. Refuses when it is running something. The last pane closes its tab.")

        @OptionGroup var connection: ConnectionOptions

        @Argument(help: "A pane token or name.")
        var pane: ControlAddress.Pane

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

        @Option(help: "A pane or drawer token, or a pane's name. This pane by default.")
        var pane: ControlAddress.Pane?

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

        @Option(help: "A pane or drawer token, or a pane's name. This pane by default.")
        var pane: ControlAddress.Pane?

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

extension ControlAddress.Pane: ExpressibleByArgument {
    public init?(argument: String) { self.init(argument) }
}
