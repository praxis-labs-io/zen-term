import ArgumentParser
import ControlProtocol
import Foundation

struct WaitCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "wait",
        abstract:
            "Wait until a pane's agent stops, its program exits, text appears, or this pane is sent something, "
            + "and print why as JSON.")

    // The app answers `timeout` at the deadline and gives up past its own margin; the client outwaits both.
    static func replyTimeout(for args: ControlArgs) -> time_t {
        time_t(ControlWire.answerWait(for: .paneWait, args) + ControlWire.answerMargin)
    }

    @OptionGroup var connection: ConnectionOptions

    @Argument(help: "A pane or drawer token.")
    var pane: Int

    @Option(help: "Answer once this text appears in output printed after the wait began.")
    var output: String?

    @Option(help: "Seconds to wait before answering timeout, at most \(ControlWire.longestPaneWait).")
    var timeout: Int = ControlWire.defaultPaneWait

    func validate() throws {
        guard (1...ControlWire.longestPaneWait).contains(timeout) else {
            throw ValidationError("--timeout must be 1 to \(ControlWire.longestPaneWait).")
        }
        if output?.isEmpty == true { throw ValidationError("--output must not be empty.") }
    }

    func run() throws {
        let args = ControlArgs(pane: pane, output: output, timeout: timeout)
        var client = try connection.client()
        client.replyTimeout = Self.replyTimeout(for: args)
        print(try JSONOutput.text(client.send(.paneWait, args, expecting: WaitResult.self)))
    }
}
