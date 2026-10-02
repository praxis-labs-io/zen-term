import Foundation

// Resolves what ssh would connect to for a host, by `ssh -G`, which reads config and never connects.
enum SSHHostResolver {
    #if DEBUG
        nonisolated(unsafe) static var destinationOverrideForTesting: ((String) -> String?)?
    #endif

    // Blocking: callers own the hop off the main thread.
    static func destination(of host: String) -> String? {
        #if DEBUG
            if let destinationOverrideForTesting { return destinationOverrideForTesting(host) }
        #endif
        guard
            case .success(let output) = Subprocess.run(URL(fileURLWithPath: "/usr/bin/ssh"), ["-G", "--", host]),
            output.status == 0
        else { return nil }
        return destination(inDump: output.stdout)
    }

    static func destination(inDump dump: String) -> String? {
        var fields: [String: String] = [:]
        for line in dump.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2, ["user", "hostname"].contains(parts[0]), fields[String(parts[0])] == nil
            else { continue }
            fields[String(parts[0])] = String(parts[1])
        }
        guard let user = fields["user"], let hostname = fields["hostname"] else { return nil }
        return "\(user)@\(hostname)"
    }

    // Bounded so a config whose `Match exec` stalls cannot take the app's worker threads with it.
    private static let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 4
        queue.qualityOfService = .userInitiated
        return queue
    }()

    static func destinations(of hosts: [String], completion: @escaping ([String: String]) -> Void) {
        let lock = NSLock()
        var found: [String: String] = [:]
        let resolveAll = hosts.map { host in
            BlockOperation {
                guard let destination = destination(of: host) else { return }
                lock.withLock { found[host] = destination }
            }
        }
        let finish = BlockOperation {
            let result = lock.withLock { found }
            DispatchQueue.main.async { completion(result) }
        }
        resolveAll.forEach(finish.addDependency)
        queue.addOperations(resolveAll, waitUntilFinished: false)
        queue.addOperation(finish)
    }
}
