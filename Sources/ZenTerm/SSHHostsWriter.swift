import Foundation

enum SSHHostsWriter {
    static let key = "ssh-hosts"

    static func set(_ host: String, on: Bool, configRoot: URL = ConfigLoader.defaultRoot) throws {
        let current = GeneralConfig.current.sshHosts
        let next = on ? (current.contains(host) ? current : current + [host]) : current.filter { $0 != host }
        try write(next, over: current, configRoot: configRoot)
    }

    static func insert(_ host: String, at index: Int, configRoot: URL = ConfigLoader.defaultRoot) throws {
        let current = GeneralConfig.current.sshHosts
        var next = current.filter { $0 != host }
        next.insert(host, at: min(max(index, 0), next.count))
        try write(next, over: current, configRoot: configRoot)
    }

    private static func write(_ next: [String], over current: [String], configRoot: URL) throws {
        guard next != current else { return }
        if next.isEmpty {
            try ConfigWriter.apply(removals: [key], configRoot: configRoot)
        } else {
            try ConfigWriter.apply(scalars: [key: next.joined(separator: ", ")], configRoot: configRoot)
        }
    }
}
