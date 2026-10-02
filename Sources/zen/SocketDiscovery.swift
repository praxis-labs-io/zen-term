import ControlProtocol
import Foundation

/// Picks the control socket: `--socket`, then `$ZEN_CONTROL_SOCK`, then the one live socket in the app's folder.
enum SocketDiscovery {
    static func resolve(
        explicit: String?, environment: [String: String], directory: URL = ControlEndpoint.directory
    ) throws(ZenFailure) -> String {
        if let explicit { return explicit }
        if let inherited = environment[ControlEndpoint.environmentKey], !inherited.isEmpty { return inherited }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let live = names.filter(ControlEndpoint.isSocketFileName).sorted()
            .map { directory.appendingPathComponent($0).path }
            .filter(isLive)
        switch live.count {
        case 0: throw .noInstance("ZenTerm isn't running.")
        case 1: return live[0]
        default:
            let listed = live.map { "  \($0)" }.joined(separator: "\n")
            throw .noInstance("More than one ZenTerm is running. Pick one with --socket:\n\(listed)")
        }
    }

    private static func isLive(_ path: String) -> Bool {
        guard let fd = try? UnixSocket.connect(to: path) else { return false }
        close(fd)
        return true
    }
}
