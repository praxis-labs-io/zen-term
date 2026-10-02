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
        let pane = environment["ZEN_PANE"].flatMap(Int.init)
        return ControlClient(path: path, caller: pane.map { ControlCaller(pane: $0) })
    }
}
