import ArgumentParser
import ControlProtocol
import Foundation

struct WaitCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "wait",
        abstract:
            "Wait until a pane's agent stops, its program exits, text appears, or this pane is sent something, "
            + "and print why as JSON. --children waits on the helpers this pane started instead.")

    @OptionGroup var connection: ConnectionOptions

    @OptionGroup var target: PaneTarget

    var pane: ControlAddress.Pane? { target.pane }

    @Option(
        help: ArgumentHelp(
            "Wait on the panes this pane started with zen pane run, in place of a pane: any answers on the first "
                + "one's news, all once none is working."))
    var children: WaitChildren?

    @Option(help: "Answer once this text appears in output printed after the wait began.")
    var output: String?

    @Option(
        help: ArgumentHelp(
            "Seconds to wait before answering timeout, at most \(ControlWire.longestPaneWait). "
                + "The default answers under the 2-minute default of agents' shell tools."))
    var timeout: Int = ControlWire.defaultPaneWait

    func validate() throws {
        switch (pane, children) {
        case (nil, nil):
            throw ValidationError("Name a pane, as an argument or with --pane, or pass --children any|all.")
        case (.some, .some): throw ValidationError("Name a pane or pass --children, not both.")
        default: break
        }
        if children == .all, output != nil { throw ValidationError("--output takes a pane or --children any.") }
        guard (1...ControlWire.longestPaneWait).contains(timeout) else {
            throw ValidationError("--timeout must be 1 to \(ControlWire.longestPaneWait).")
        }
        if output?.isEmpty == true { throw ValidationError("--output must not be empty.") }
        if output?.contains(where: \.isNewline) == true {
            throw ValidationError("--output matches within one line, so it takes no newline.")
        }
    }

    func run() throws {
        let args = ControlArgs(pane: pane, output: output, timeout: timeout, children: children)
        var client = try connection.client()
        client.replyTimeout = ControlClient.replyTimeout(for: .paneWait, args)
        print(try JSONOutput.text(client.send(.paneWait, args, expecting: WaitResult.self)))
    }
}
