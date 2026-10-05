import Foundation

extension Notification.Name {
    static let sshHostStatusDidChange = Notification.Name("sshHostStatusDidChange")
}

// Each SSH host's status and resolved destination for every window: Offline until the probe reaches it, overridden by a live connection.
@MainActor
final class SSHHostStatusCenter {
    static let shared = SSHHostStatusCenter()

    init() {}

    private var reachable: Set<SSHHostID> = []
    private var connected: Set<SSHHostID> = []
    private var destinations: [SSHHostID: String] = [:]

    func status(of host: SSHHostID) -> SSHHostStatus {
        if connected.contains(host) { return .connected }
        return reachable.contains(host) ? .online : .offline
    }

    func setConnected(_ isConnected: Bool, host: SSHHostID) {
        announcingChange(of: host) {
            if isConnected { connected.insert(host) } else { connected.remove(host) }
        }
    }

    func setReachable(_ isReachable: Bool, host: SSHHostID) {
        announcingChange(of: host) {
            if isReachable { reachable.insert(host) } else { reachable.remove(host) }
        }
    }

    var destinationRequestHandler: (([String]) -> Void)?

    func requestDestinations(of hosts: [String]) { destinationRequestHandler?(hosts) }

    func destination(of host: SSHHostID) -> String? { destinations[host] }

    func setDestination(_ destination: String?, host: SSHHostID) {
        guard destinations[host] != destination else { return }
        destinations[host] = destination
        NotificationCenter.default.post(name: .sshHostStatusDidChange, object: nil)
    }

    // Only a real change announces itself, so a probe round that confirms what is shown redraws nothing.
    private func announcingChange(of host: SSHHostID, _ change: () -> Void) {
        let before = status(of: host)
        change()
        guard status(of: host) != before else { return }
        NotificationCenter.default.post(name: .sshHostStatusDidChange, object: nil)
    }
}
