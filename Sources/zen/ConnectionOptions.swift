import ArgumentParser
import ControlProtocol
import Foundation

struct ConnectionOptions: ParsableArguments {
    @Option(help: "The control socket to use. Defaults to $ZEN_CONTROL_SOCK, or the one running ZenTerm.")
    var socket: String?

    func client(environment: [String: String] = ProcessInfo.processInfo.environment) throws(ZenFailure)
        -> ControlClient
    {
        let path = try SocketDiscovery.resolve(explicit: socket, environment: environment)
        return ControlClient(path: path, caller: Self.caller(for: path, environment: environment))
    }

    /// A pane token is only meaningful to the instance that minted it, which is the one in `$ZEN_CONTROL_SOCK`.
    static func caller(for path: String, environment: [String: String]) -> ControlCaller? {
        guard path == environment[ControlEndpoint.environmentKey],
            let pane = environment["ZEN_PANE"].flatMap(Int.init)
        else { return nil }
        return ControlCaller(pane: pane)
    }
}
