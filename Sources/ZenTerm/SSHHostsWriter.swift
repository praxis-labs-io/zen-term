import Foundation

enum SSHHostsWriter {
    static let key = "ssh-host"
    static let offKey = "ssh-host-off"

    static func add(_ host: SSHHostEntry, at index: Int? = nil, configRoot: URL = ConfigLoader.defaultRoot) throws {
        let config = GeneralConfig.current
        if index == nil, config.sshHosts.contains(where: { $0.alias == host.alias }) { return }
        var next = config.sshHosts.filter { $0.alias != host.alias }
        next.insert(host, at: min(max(index ?? next.count, 0), next.count))
        try write(on: next, off: config.sshHostsOff.filter { $0.alias != host.alias }, configRoot: configRoot)
    }

    static func addOff(_ host: SSHHostEntry, at index: Int, configRoot: URL = ConfigLoader.defaultRoot) throws {
        let config = GeneralConfig.current
        var next = config.sshHostsOff.filter { $0.alias != host.alias }
        next.insert(host, at: min(max(index, 0), next.count))
        try write(on: config.sshHosts.filter { $0.alias != host.alias }, off: next, configRoot: configRoot)
    }

    static func rename(
        _ alias: String, to name: String?, isConfigHost: Bool = false, configRoot: URL = ConfigLoader.defaultRoot
    ) throws {
        let config = GeneralConfig.current
        let renamed = { (hosts: [SSHHostEntry]) in
            hosts.map { $0.alias == alias ? SSHHostEntry(alias: alias, name: name) : $0 }
        }
        guard (config.sshHosts + config.sshHostsOff).contains(where: { $0.alias == alias }) else {
            guard isConfigHost else { throw NoLongerListed() }
            guard let name else { return }
            return try addOff(
                SSHHostEntry(alias: alias, name: name), at: config.sshHostsOff.count, configRoot: configRoot)
        }
        try write(on: renamed(config.sshHosts), off: renamed(config.sshHostsOff), configRoot: configRoot)
    }

    struct NoLongerListed: LocalizedError {
        var errorDescription: String? { "it's no longer in the host list" }
    }

    static func turnOff(_ alias: String, configRoot: URL = ConfigLoader.defaultRoot) throws {
        let config = GeneralConfig.current
        guard let host = config.sshHosts.first(where: { $0.alias == alias }) else { return }
        try write(
            on: config.sshHosts.filter { $0.alias != alias },
            off: config.sshHostsOff.filter { $0.alias != alias } + [host], configRoot: configRoot)
    }

    static func remove(_ alias: String, configRoot: URL = ConfigLoader.defaultRoot) throws {
        let config = GeneralConfig.current
        try write(
            on: config.sshHosts.filter { $0.alias != alias }, off: config.sshHostsOff.filter { $0.alias != alias },
            configRoot: configRoot)
    }

    private static func write(on: [SSHHostEntry], off: [SSHHostEntry], configRoot: URL) throws {
        let config = GeneralConfig.current
        guard on != config.sshHosts || off != config.sshHostsOff else { return }
        try ConfigWriter.apply(sshHosts: on, sshHostsOff: off, configRoot: configRoot)
    }
}
