import ArgumentParser
import ControlProtocol

struct PaneCommands: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pane", abstract: "Split, focus, close, type into, interrupt, read and inspect panes.",
        subcommands: [Split.self, Focus.self, Close.self, Send.self, Keys.self, Interrupt.self, Read.self, Get.self])

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
            abstract: "Paste text into a pane. Control characters arrive as spaces.",
            discussion:
                "Into an agent, it waits until the person has not typed into the pane for 2 seconds, "
                + "at most \(ControlWire.longestDraftHold), and refuses while the agent waits on the user.")

        @OptionGroup var connection: ConnectionOptions

        @Argument(help: "The text. Several lines arrive as one block.")
        var text: String

        @Option(help: "A pane or drawer token. This pane by default.")
        var pane: Int?

        @Flag(help: "Press Return after it, which runs the block once.")
        var enter = false

        @Flag(help: "Send it to an agent that is waiting on the user.")
        var force = false

        @Flag(help: "Then wait on the pane as zen wait does, and print why as JSON.")
        var wait = false

        @Option(help: "With --wait, seconds to wait before answering timeout, at most \(ControlWire.longestPaneWait).")
        var timeout: Int = ControlWire.defaultPaneWait

        func validate() throws {
            guard (1...ControlWire.longestPaneWait).contains(timeout) else {
                throw ValidationError("--timeout must be 1 to \(ControlWire.longestPaneWait).")
            }
        }

        func run() throws {
            let args = ControlArgs(
                force: force, pane: pane, text: text, enter: enter, timeout: wait ? timeout : nil, wait: wait)
            var client = try connection.client()
            client.replyTimeout = ControlClient.replyTimeout(for: .paneSend, args)
            if wait {
                print(try JSONOutput.text(client.send(.paneSend, args, expecting: WaitResult.self)))
            } else {
                _ = try client.send(.paneSend, args, expecting: NoPayload.self)
            }
        }
    }

    struct Keys: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Press keys in a pane, in order, as keystrokes rather than a paste.")

        private static let names = "One of " + PaneKey.names.joined(separator: ", ") + "."

        @OptionGroup var connection: ConnectionOptions

        @Argument(help: "A pane or drawer token.")
        var pane: Int

        @Argument(help: ArgumentHelp("The keys.", discussion: Keys.names))
        var keys: [PaneKey]

        func run() throws {
            let args = ControlArgs(pane: pane, keys: keys.map(\.name))
            _ = try connection.client().send(.paneKeys, args, expecting: NoPayload.self)
        }
    }

    struct Interrupt: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Stop an agent's turn with Escape, or send SIGINT to what a pane runs.")

        @OptionGroup var connection: ConnectionOptions

        @Argument(help: "A pane or drawer token.")
        var pane: Int

        func run() throws {
            _ = try connection.client().send(.paneInterrupt, ControlArgs(pane: pane), expecting: NoPayload.self)
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

    struct Get: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Print one pane's state as JSON: its title, folder, program and agent status.")

        @OptionGroup var connection: ConnectionOptions

        @Argument(help: "A pane or drawer token. This pane by default.")
        var pane: Int?

        func run() throws {
            let got = try connection.client().send(.paneGet, ControlArgs(pane: pane), expecting: ListResult.Pane.self)
            print(try JSONOutput.text(got))
        }
    }
}

extension PaneDirection: ExpressibleByArgument {}

extension PaneKey: ExpressibleByArgument {
    public init?(argument: String) { self.init(name: argument) }
}
