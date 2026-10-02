import Foundation

enum SSHHostsWriter {
    static let key = "ssh-hosts"

    static func set(_ host: String, on: Bool, configRoot: URL = ConfigLoader.defaultRoot) throws {
        let current = GeneralConfig.current.sshHosts
        let next = on ? (current.contains(host) ? current : current + [host]) : current.filter { $0 != host }
        guard next != current else { return }
        if next.isEmpty {
            try ConfigWriter.apply(removals: [key], configRoot: configRoot)
        } else {
            try ConfigWriter.apply(scalars: [key: next.joined(separator: ", ")], configRoot: configRoot)
        }
    }
}
