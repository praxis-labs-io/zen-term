import Foundation

// Resolves what ssh would connect to for a host, by `ssh -G`, which reads config and never connects.
enum SSHHostResolver {
    enum Endpoint: Equatable {
        case direct(hostname: String, port: UInt16)
        case proxied
    }

    struct Resolution: Equatable {
        let endpoint: Endpoint?
        let destination: String?
    }

    #if DEBUG
        nonisolated(unsafe) static var destinationOverrideForTesting: ((String) -> String?)?
    #endif

    // A `Match exec` that never returns would otherwise hold a worker forever.
    private static let resolveTimeout: TimeInterval = 5
    private static let defaultPort: UInt16 = 22

    // Blocking: callers own the hop off the main thread.
    static func destination(of host: String) -> String? {
        #if DEBUG
            if let destinationOverrideForTesting { return destinationOverrideForTesting(host) }
        #endif
        return dump(of: host).flatMap(destination(inDump:))
    }

    // Blocking: callers own the hop off the main thread.
    static func endpoint(of host: String) -> Endpoint? {
        dump(of: host).flatMap(endpoint(inDump:))
    }

    // Blocking: callers own the hop off the main thread.
    static func resolution(of host: String) -> Resolution? {
        dump(of: host).map { Resolution(endpoint: endpoint(inDump: $0), destination: destination(inDump: $0)) }
    }

    // Blocking: callers own the hop off the main thread.
    static func launchForm(of host: String) -> SSHLaunch.Form {
        launchForm(inDump: dump(of: host))
    }

    // An unread config may hold a `RemoteCommand`, and only the plain form survives one.
    static func launchForm(inDump dump: String?) -> SSHLaunch.Form {
        guard let dump, fields(inDump: dump)["remotecommand"] == nil else { return .plain }
        return .loginShell
    }

    static func destination(inDump dump: String) -> String? {
        let fields = fields(inDump: dump)
        guard let user = fields["user"], let hostname = fields["hostname"] else { return nil }
        return "\(user)@\(hostname)"
    }

    static func endpoint(inDump dump: String) -> Endpoint? {
        let fields = fields(inDump: dump)
        if fields["proxyjump"] != nil || fields["proxycommand"] != nil { return .proxied }
        guard let hostname = fields["hostname"] else { return nil }
        return .direct(hostname: hostname, port: fields["port"].flatMap { UInt16($0) } ?? defaultPort)
    }

    private static func dump(of host: String) -> String? {
        guard
            case .success(let output) = Subprocess.run(
                URL(fileURLWithPath: "/usr/bin/ssh"), ["-G", "--", host], timeout: resolveTimeout),
            output.status == 0
        else { return nil }
        return output.stdout
    }

    private static func fields(inDump dump: String) -> [String: String] {
        var fields: [String: String] = [:]
        for line in dump.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2, fields[String(parts[0])] == nil else { continue }
            fields[String(parts[0])] = String(parts[1])
        }
        return fields
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
