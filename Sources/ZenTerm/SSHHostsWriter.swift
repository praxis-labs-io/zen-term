import Foundation

enum SSHHostsWriter {
    static let key = "ssh-host"

    static func add(_ host: SSHHostEntry, at index: Int? = nil, configRoot: URL = ConfigLoader.defaultRoot) throws {
        let current = GeneralConfig.current.sshHosts
        if index == nil, current.contains(where: { $0.alias == host.alias }) { return }
        var next = current.filter { $0.alias != host.alias }
        next.insert(host, at: min(max(index ?? next.count, 0), next.count))
        try write(next, over: current, configRoot: configRoot)
    }

    static func rename(_ alias: String, to name: String?, configRoot: URL = ConfigLoader.defaultRoot) throws {
        let current = GeneralConfig.current.sshHosts
        let next = current.map { $0.alias == alias ? SSHHostEntry(alias: alias, name: name) : $0 }
        try write(next, over: current, configRoot: configRoot)
    }

    static func remove(_ alias: String, configRoot: URL = ConfigLoader.defaultRoot) throws {
        let current = GeneralConfig.current.sshHosts
        try write(current.filter { $0.alias != alias }, over: current, configRoot: configRoot)
    }

    private static func write(_ next: [SSHHostEntry], over current: [SSHHostEntry], configRoot: URL) throws {
        guard next != current else { return }
        try ConfigWriter.apply(sshHosts: next, configRoot: configRoot)
    }
}
