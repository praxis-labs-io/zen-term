import AppLog
import Foundation

// Ends the ssh masters a force-quit or crashed ZenTerm left running, and removes their sockets.
enum SSHSocketSweep {
    struct Effects {
        var isAlive: (pid_t) -> Bool
        var resolveMaster: (URL) -> pid_t?
        var endMaster: (pid_t) -> Void
    }

    // The sweep cannot name the host a socket was for, and an ssh control command never contacts it.
    private static let placeholderHost = SSHHostID(name: "zenterm-sweep.invalid")

    static func start() {
        let directories = [SSHLaunch.socketDirectory, SSHLaunch.fallbackDirectory]
        DispatchQueue.global(qos: .utility).async { sweep(directories, effects: .live) }
    }

    static func sweep(_ directories: [URL], effects: Effects, ownPID: pid_t = getpid()) {
        for directory in directories {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            for name in names {
                guard let owner = owner(ofSocketNamed: name), owner != ownPID, !effects.isAlive(owner) else { continue }
                let path = directory.appendingPathComponent(name)
                guard let master = effects.resolveMaster(path) else { continue }
                Log.info("ssh: ending a master left by ZenTerm pid \(owner)", category: .workspace)
                effects.endMaster(master)
            }
        }
    }

    static func owner(ofSocketNamed name: String) -> pid_t? {
        let parts = name.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[1].count == 8, parts[1].allSatisfy(\.isHexDigit),
            let pid = pid_t(parts[0]), pid > 0
        else { return nil }
        return pid
    }
}

extension SSHSocketSweep.Effects {
    static let live = SSHSocketSweep.Effects(
        isAlive: { pid in kill(pid, 0) == 0 || errno == EPERM },
        resolveMaster: { path in SSHConnection.Watchers.master(of: SSHSocketSweep.placeholderHost, at: path) },
        endMaster: { pid in SSHConnection.Watchers.terminate(master: pid) })
}
