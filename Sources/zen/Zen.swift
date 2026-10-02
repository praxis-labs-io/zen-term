import ArgumentParser
import ControlProtocol

struct Zen: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "zen",
        abstract: "Control a running ZenTerm.",
        subcommands: [Hello.self, List.self, WorkspaceCommands.self, TabCommands.self])

    // Parses `--socket` before the subcommand; argument-parser hands the value to the subcommand's own copy.
    @OptionGroup var connection: ConnectionOptions

    struct Hello: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Print the app version and the protocol version it speaks, as JSON.")

        @OptionGroup var connection: ConnectionOptions

        func run() throws {
            let hello = try connection.client().send(.hello, expecting: HelloResult.self)
            print(try JSONOutput.text(hello))
        }
    }

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Print every window, workspace, tab, pane and drawer, as JSON.")

        @OptionGroup var connection: ConnectionOptions

        @Flag(help: "Print an indented tree instead of JSON.")
        var pretty = false

        func run() throws {
            let list = try connection.client().send(.list, expecting: ListResult.self)
            print(pretty ? ListTree.text(list) : try JSONOutput.text(list))
        }
    }

    static func exitCode(running arguments: [String]) -> Int32 {
        var command: ParsableCommand
        do {
            command = try parseAsRoot(arguments)
        } catch {
            return finish(error, usage: true)
        }
        do {
            try command.run()
            return 0
        } catch {
            return finish(error, usage: false)
        }
    }

    private static func finish(_ error: Error, usage: Bool) -> Int32 {
        if let failure = error as? ZenFailure {
            printError("zen: \(failure.message)")
            return failure.exitCode
        }
        let code = exitCode(for: error)
        if code == .success {
            print(fullMessage(for: error))
            return 0
        }
        printError(fullMessage(for: error))
        return usage || error is ValidationError ? ZenFailure.usageCode : ZenFailure.appErrorCode
    }

    private static func printError(_ text: String) {
        var standardError = StandardError()
        print(text, to: &standardError)
    }
}
