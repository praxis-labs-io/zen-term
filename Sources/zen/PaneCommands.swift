import ArgumentParser
import ControlProtocol
import Foundation

struct PaneCommands: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pane",
        abstract: "Run programs in, split, focus, close, type into, interrupt, read and inspect panes.",
        subcommands: [
            Run.self, Split.self, Focus.self, Close.self, Send.self, Keys.self, Interrupt.self, Read.self, Get.self,
        ])

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

        // Passthrough capture keeps a `--` that separates the command from zen's options.
        var commandLine: String {
            let words = command.first == "--" ? Array(command.dropFirst()) : command
            return words.count == 1 ? words[0] : words.map(Self.shellWord).joined(separator: " ")
        }

        private static let shellSafe = CharacterSet(charactersIn: "-_./=:,+@%")

        // The app runs the line through the user's shell, so each argument is quoted to arrive whole.
        private static func shellWord(_ word: String) -> String {
            let plain = word.unicodeScalars.allSatisfy {
                $0.isASCII && (shellSafe.contains($0) || $0.properties.isAlphabetic || ("0"..."9").contains($0))
            }
            guard word.isEmpty || !plain else { return word }
            return "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }

        func validate() throws {
            if commandLine.isEmpty { throw ValidationError("pane run needs a command to run.") }
            if let name, !ControlAddress.Pane.isValidName(name) {
                throw ValidationError("--name needs at least one character that is not a digit or a space.")
            }
        }

        func run() throws {
            let args = ControlArgs(
                cmd: commandLine, focus: focus, pane: pane, name: name, task: task, split: split,
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
            abstract: "Paste text into a pane. Control characters arrive as spaces.",
            discussion:
                "Into an agent, it waits until the person has not typed into the pane for 2 seconds, "
                + "at most \(ControlWire.longestDraftHold), and refuses while the agent waits on the user.")

        @OptionGroup var connection: ConnectionOptions

        @Argument(help: "The text. Several lines arrive as one block.")
        var text: String

        @Option(help: "A pane or drawer token, or a pane's name. This pane by default.")
        var pane: ControlAddress.Pane?

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

        @Argument(help: "A pane or drawer token, or a pane's name.")
        var pane: ControlAddress.Pane

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

        @Argument(help: "A pane or drawer token, or a pane's name.")
        var pane: ControlAddress.Pane

        func run() throws {
            _ = try connection.client().send(.paneInterrupt, ControlArgs(pane: pane), expecting: NoPayload.self)
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

    struct Get: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Print one pane's state as JSON: its title, folder, program and agent status.")

        @OptionGroup var connection: ConnectionOptions

        @Argument(help: "A pane or drawer token, or a pane's name. This pane by default.")
        var pane: ControlAddress.Pane?

        func run() throws {
            let got = try connection.client().send(.paneGet, ControlArgs(pane: pane), expecting: ListResult.Pane.self)
            print(try JSONOutput.text(got))
        }
    }
}

extension PaneDirection: ExpressibleByArgument {}

extension ControlAddress.Pane: ExpressibleByArgument {
    public init?(argument: String) { self.init(argument) }
}

extension PaneKey: ExpressibleByArgument {
    public init?(argument: String) { self.init(name: argument) }
}
