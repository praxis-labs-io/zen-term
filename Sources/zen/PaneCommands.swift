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
            abstract: "Run a program in a new pane, out of sight, and print the pane as JSON.",
            discussion: "Run from an agent's pane, it opens in a hidden float, which its row in the Agents list "
                + "opens. A float closes when that agent exits. Otherwise, or with --outlive-parent, it opens in a "
                + "tab behind this one. The pane closes when the program exits, unless --keep. With --task, zen "
                + "answers once the task is sent, or says why it was not.")

        @OptionGroup var connection: ConnectionOptions

        @Option(help: "A name for the pane, unique among open panes. It works anywhere a pane token does.")
        var name: String?

        @Option(help: "A first message to send the program once it reports it is ready.")
        var task: String?

        @Option(help: "Split the pane instead of opening a float or tab: right or down.")
        var split: PaneDirection?

        @Flag(
            help: "Open it in a hidden float, from a pane an agent runs in or started. It closes when that agent exits."
        )
        var float = false

        @Flag(help: "Open it in a tab behind this one.")
        var tab = false

        @Option(help: "The pane to split, or whose tab or workspace gets it. This pane by default.")
        var pane: ControlAddress.Pane?

        @Option(help: "The folder to start in, instead of this one.")
        var cwd: String?

        @Flag(help: "Show it.")
        var focus = false

        @Flag(help: "Keep the pane open after the program exits.")
        var keep = false

        @Flag(help: "Keep the pane open after this pane closes. Otherwise it closes with it.")
        var outliveParent = false

        @Flag(help: "Then wait on the pane as zen wait does, and print why as JSON.")
        var wait = false

        @Option(help: "With --wait, seconds to wait before answering timeout, at most \(ControlWire.longestPaneWait).")
        var timeout: Int = ControlWire.defaultPaneWait

        @Option(
            help: ArgumentHelp(
                "With --wait, answer once this text appears in the pane's output, matched as the pane opens, "
                    + "or with --task, as the task is sent."))
        var output: String?

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

        // Passthrough capture takes a leading `--help` as the command, so it is asked for here.
        func validate() throws {
            if let first = command.first, ["--help", "-h"].contains(first) { throw CleanExit.helpRequest(self) }
            if commandLine.isEmpty { throw ValidationError("pane run needs a command to run.") }
            if float, tab { throw ValidationError("Pass --float or --tab, not both.") }
            if let name, !ControlAddress.Pane.isValidName(name) {
                throw ValidationError("--name needs at least one character that is not a digit or a space.")
            }
            guard (1...ControlWire.longestPaneWait).contains(timeout) else {
                throw ValidationError("--timeout must be 1 to \(ControlWire.longestPaneWait).")
            }
            if output != nil, !wait { throw ValidationError("--output needs --wait.") }
            if output?.isEmpty == true { throw ValidationError("--output must not be empty.") }
            if output?.contains(where: \.isNewline) == true {
                throw ValidationError("--output matches within one line, so it takes no newline.")
            }
        }

        func args(in folder: String) throws -> ControlArgs {
            ControlArgs(
                cwd: try cwd.map { try CommandPath.folder($0, in: folder) }, cmd: commandLine, focus: focus, pane: pane,
                name: name, output: output, timeout: wait ? timeout : nil,
                task: task, split: split, float: float ? true : (tab ? false : nil), keep: keep,
                outliveParent: outliveParent, wait: wait)
        }

        func run() throws {
            let args = try args(in: FileManager.default.currentDirectoryPath)
            var client = try connection.client()
            client.replyTimeout = ControlClient.replyTimeout(for: .paneRun, args)
            if wait {
                print(try JSONOutput.text(client.send(.paneRun, args, expecting: WaitResult.self)))
            } else {
                print(try JSONOutput.text(client.send(.paneRun, args, expecting: PaneRunResult.self)))
            }
        }
    }

    struct Split: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Open a pane beside one, leaving focus where it is, and print its token as JSON.",
            discussion: PaneTarget.thisPaneByDefault)

        @OptionGroup var connection: ConnectionOptions

        @OptionGroup var target: PaneTarget

        var pane: ControlAddress.Pane? { target.pane }

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

        @OptionGroup var target: PaneTarget

        var pane: ControlAddress.Pane? { target.pane }

        func validate() throws { _ = try target.required() }

        func run() throws {
            _ = try connection.client().send(.paneFocus, ControlArgs(pane: pane), expecting: NoPayload.self)
        }
    }

    struct Close: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Close a pane. Refuses when it is running something. The last pane closes its tab.")

        @OptionGroup var connection: ConnectionOptions

        @OptionGroup var target: PaneTarget

        @Flag(help: "Close it anyway.")
        var force = false

        var pane: ControlAddress.Pane? { target.pane }

        func validate() throws { _ = try target.required() }

        func run() throws {
            let args = ControlArgs(force: force, pane: pane)
            _ = try connection.client().send(.paneClose, args, expecting: NoPayload.self)
        }
    }

    struct Send: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Paste text into a pane. Control characters arrive as spaces.",
            usage: "zen pane send [<pane>] <text> [<options>]",
            discussion:
                "Into an agent whose person has unsent text at its prompt, it is queued until they send or clear "
                + "it, or, in Claude Code, stop typing for 60 seconds, and prints {\"queued\":true}. "
                + "It refuses while the agent waits on the user. " + PaneTarget.thisPaneByDefault)

        @OptionGroup var connection: ConnectionOptions

        @Argument(help: ArgumentHelp("The pane, when the text follows it. Otherwise the text.", valueName: "pane"))
        var leading: String

        @Argument(help: ArgumentHelp("The text. Several lines arrive as one block.", valueName: "text"))
        var trailing: String?

        @Option(name: .customLong("pane"), help: "The pane, as an option instead of an argument.")
        var paneOption: ControlAddress.Pane?

        var pane: ControlAddress.Pane? { trailing == nil ? paneOption : ControlAddress.Pane(leading) }

        var text: String { trailing ?? leading }

        @Flag(help: "Press Return after it, which runs the block once.")
        var enter = false

        @Flag(help: "Send it to an agent that is waiting on the user.")
        var force = false

        @Flag(help: "Then wait on the pane as zen wait does, and print why as JSON.")
        var wait = false

        @Option(help: "With --wait, seconds to wait before answering timeout, at most \(ControlWire.longestPaneWait).")
        var timeout: Int = ControlWire.defaultPaneWait

        func validate() throws {
            if trailing != nil, paneOption != nil { throw PaneTarget.namedTwice }
            guard (1...ControlWire.longestPaneWait).contains(timeout) else {
                throw ValidationError("--timeout must be 1 to \(ControlWire.longestPaneWait).")
            }
        }

        func run() throws {
            let args = ControlArgs(
                force: force, pane: pane, text: text, enter: enter, timeout: wait ? timeout : nil, wait: wait)
            var client = try connection.client()
            if wait {
                client.replyTimeout = ControlClient.replyTimeout(for: .paneSend, args)
                print(try JSONOutput.text(client.send(.paneSend, args, expecting: WaitResult.self)))
            } else if try client.send(.paneSend, args, expecting: PaneSendResult.self).queued == true {
                print(try JSONOutput.text(PaneSendResult(queued: true)))
            }
        }
    }

    struct Keys: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Press keys in a pane, in order, as keystrokes rather than a paste.",
            usage: "zen pane keys [<pane>] <key> ... [<options>]")

        private static let names = "A key is one of " + PaneKey.names.joined(separator: ", ") + "."

        @OptionGroup var connection: ConnectionOptions

        @Argument(
            help: ArgumentHelp(
                "The pane, unless --pane names it, then the keys.", discussion: Keys.names, valueName: "key"))
        var words: [String] = []

        @Option(name: .customLong("pane"), help: "The pane, as an option instead of an argument.")
        var paneOption: ControlAddress.Pane?

        @Flag(help: "Press them into an agent that is waiting on the user.")
        var force = false

        var pane: ControlAddress.Pane? { paneOption ?? words.first.map(ControlAddress.Pane.init) }

        var keys: [PaneKey] { (paneOption == nil ? words.dropFirst() : words[...]).compactMap(PaneKey.init(name:)) }

        var args: ControlArgs { ControlArgs(force: force, pane: pane, keys: keys.map(\.name)) }

        func validate() throws {
            guard pane != nil else { throw PaneTarget.unnamed }
            let named = paneOption == nil ? words.dropFirst() : words[...]
            if named.isEmpty { throw ValidationError("Name at least one key. \(Self.names)") }
            if let unknown = named.first(where: { PaneKey(name: $0) == nil }) {
                throw ValidationError("\(unknown) is not a key. \(Self.names)")
            }
        }

        func run() throws {
            _ = try connection.client().send(.paneKeys, args, expecting: NoPayload.self)
        }
    }

    struct Interrupt: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Stop an agent's turn with Escape, or send SIGINT to what a pane runs.")

        @OptionGroup var connection: ConnectionOptions

        @OptionGroup var target: PaneTarget

        var pane: ControlAddress.Pane? { target.pane }

        func validate() throws { _ = try target.required() }

        func run() throws {
            _ = try connection.client().send(.paneInterrupt, ControlArgs(pane: pane), expecting: NoPayload.self)
        }
    }

    struct Read: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract:
                "Print a pane's text: the rows on screen, its last lines with --lines, or what it printed since its "
                + "last task with --since-task.",
            discussion: PaneTarget.thisPaneByDefault)

        @OptionGroup var connection: ConnectionOptions

        @OptionGroup var target: PaneTarget

        var pane: ControlAddress.Pane? { target.pane }

        @Option(help: "Print the last this many lines, scrollback included.")
        var lines: Int?

        @Flag(
            help: ArgumentHelp(
                "Print from the row where the pane's last task or message sent with --enter began, its echo included. "
                    + "Cells as they stand, not a log. A full-screen program already showing reads from the row its "
                    + "cursor was on as the task arrived."))
        var sinceTask = false

        func validate() throws {
            if let lines, lines < 1 { throw ValidationError("--lines must be 1 or more.") }
            if lines != nil, sinceTask { throw ValidationError("--lines and --since-task do not go together.") }
        }

        func run() throws {
            let args = ControlArgs(pane: pane, lines: lines, since: sinceTask ? .task : nil)
            let read = try connection.client().send(.paneRead, args, expecting: PaneText.self)
            print(read.text)
            guard read.truncated == true else { return }
            var standardError = StandardError()
            print(
                "zen: where the task began is no longer readable, so this reads from the oldest row or the screen showing.",
                to: &standardError)
        }
    }

    struct Get: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Print one pane's state as JSON: its title, folder, program and agent status.",
            discussion: PaneTarget.thisPaneByDefault)

        @OptionGroup var connection: ConnectionOptions

        @OptionGroup var target: PaneTarget

        var pane: ControlAddress.Pane? { target.pane }

        func run() throws {
            let got = try connection.client().send(.paneGet, ControlArgs(pane: pane), expecting: ListResult.Pane.self)
            print(try JSONOutput.text(got))
        }
    }
}

extension PaneDirection: ExpressibleByArgument {}

extension WaitChildren: ExpressibleByArgument {}

extension ControlAddress.Pane: ExpressibleByArgument {
    public init?(argument: String) { self.init(argument) }
}

extension PaneKey: ExpressibleByArgument {
    public init?(argument: String) { self.init(name: argument) }
}
