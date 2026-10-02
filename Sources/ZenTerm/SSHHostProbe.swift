import AppKit
import Network

// Keeps each SSH host's reachability current by connecting to its ssh port and reading the banner, never logging in.
@MainActor
final class SSHHostProbe {
    #if DEBUG
        nonisolated(unsafe) static var resolveOverrideForTesting: ((String) -> SSHHostResolver.Endpoint?)?
        nonisolated(unsafe) static var bannerOverrideForTesting: ((String, UInt16) -> Bool)?
    #endif

    private static let roundInterval: TimeInterval = 60
    private static let roundTolerance: TimeInterval = 10
    nonisolated private static let connectTimeout = 5
    nonisolated private static let bannerTimeout: TimeInterval = 5
    // RFC 4253 4.2 caps a greeting line at 255 bytes; past a few lines of preamble the server is not sshd.
    nonisolated private static let maxGreetingLine = 255
    nonisolated private static let maxGreetingLines = 8
    // Path updates arrive in bursts while an interface comes up, and a wake lands before the interface is back.
    private static let networkSettle: TimeInterval = 1
    nonisolated private static let banner = Data("SSH-".utf8)

    private static let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 4
        queue.qualityOfService = .utility
        return queue
    }()

    private let center: SSHHostStatusCenter
    private var hosts: [String] = []
    private var proxied: Set<String> = []
    // `ssh -G` reruns `Match exec`, which can prompt, so a host resolves once per config and network.
    private var endpoints: [String: SSHHostResolver.Endpoint] = [:]
    private var inFlight: Set<String> = []
    private var generation = 0
    private var isNetworkUp = true
    private var isStarted = false
    private var isWatching = false
    private var timer: Timer?
    private var pathMonitor: NWPathMonitor?
    private var lastPath: NWPath?
    private var pendingSettle: DispatchWorkItem?

    init(center: SSHHostStatusCenter) {
        self.center = center
    }

    func start(hosts: [String]) {
        isStarted = true
        let app = NotificationCenter.default
        let workspace = NSWorkspace.shared.notificationCenter
        observe(app, NSApplication.didBecomeActiveNotification) { $0.appDidBecomeActive() }
        observe(app, NSApplication.didResignActiveNotification) { $0.refreshTimer() }
        observe(workspace, NSWorkspace.didWakeNotification) { $0.systemDidWake() }
        setHosts(hosts)
    }

    func setHosts(_ next: [String]) {
        for host in hosts where !next.contains(host) {
            proxied.remove(host)
            center.setReachable(true, host: SSHHostID(name: host))
        }
        let added = next.filter { !hosts.contains($0) }
        hosts = next
        endpoints = [:]
        refreshWatching()
        probe(added)
    }

    func probeAll() { probe(hosts) }

    func networkChanged(isUp: Bool) {
        generation += 1
        isNetworkUp = isUp
        endpoints = [:]
        pendingSettle?.cancel()
        guard isUp else {
            for host in hosts where !proxied.contains(host) {
                center.setReachable(false, host: SSHHostID(name: host))
            }
            return
        }
        probeOnceSettled()
    }

    func systemDidWake() { probeOnceSettled() }

    private func probeOnceSettled() {
        pendingSettle?.cancel()
        let settle = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.probeAll() } }
        pendingSettle = settle
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.networkSettle, execute: settle)
    }

    private func appDidBecomeActive() {
        refreshTimer()
        probeAll()
    }

    private func observe(
        _ notifications: NotificationCenter, _ name: Notification.Name, _ handle: @escaping (SSHHostProbe) -> Void
    ) {
        _ = notifications.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                handle(self)
            }
        }
    }

    // A watch that stopped knows nothing of the network since, so a new one starts up until its monitor says otherwise.
    private func refreshWatching() {
        refreshTimer()
        let watches = !hosts.isEmpty
        guard watches != isWatching else { return }
        isWatching = watches
        pathMonitor?.cancel()
        pathMonitor = nil
        lastPath = nil
        pendingSettle?.cancel()
        isNetworkUp = true
        guard watches, isStarted else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.pathUpdated(path) } }
        }
        monitor.start(queue: DispatchQueue(label: "ZenTerm.SSHHostProbe.path"))
        pathMonitor = monitor
    }

    private func pathUpdated(_ path: NWPath) {
        defer { lastPath = path }
        let isUp = path.status == .satisfied
        guard let lastPath else { return firstPathReported(isUp: isUp) }
        guard lastPath != path else { return }
        networkChanged(isUp: isUp)
    }

    func firstPathReported(isUp: Bool) {
        guard isUp != isNetworkUp else { return }
        networkChanged(isUp: isUp)
    }

    private func refreshTimer() {
        let runs = isStarted && !hosts.isEmpty && NSApp.isActive
        guard runs != (timer != nil) else { return }
        timer?.invalidate()
        timer = nil
        guard runs else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: Self.roundInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.probeAll() }
        }
        timer.tolerance = Self.roundTolerance
        self.timer = timer
    }

    private func probe(_ targets: [String]) {
        guard isNetworkUp else { return }
        for host in targets where !inFlight.contains(host) && center.status(of: SSHHostID(name: host)) != .connected {
            inFlight.insert(host)
            let generation = self.generation
            let cached = endpoints[host]
            Self.queue.addOperation { [weak self] in
                let endpoint = cached ?? Self.resolve(host)
                let isReachable = endpoint.map(Self.isReachable) ?? false
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.land(endpoint, isReachable: isReachable, for: host, generation: generation)
                    }
                }
            }
        }
    }

    // An answer from before a network change describes the old network, so the host is asked again.
    private func land(
        _ endpoint: SSHHostResolver.Endpoint?, isReachable: Bool, for host: String, generation: Int
    ) {
        inFlight.remove(host)
        guard hosts.contains(host) else { return }
        guard generation == self.generation else { return probe([host]) }
        endpoints[host] = endpoint
        if endpoint == .proxied { proxied.insert(host) } else { proxied.remove(host) }
        center.setReachable(isReachable, host: SSHHostID(name: host))
    }

    nonisolated private static func resolve(_ host: String) -> SSHHostResolver.Endpoint? {
        #if DEBUG
            if let resolveOverrideForTesting { return resolveOverrideForTesting(host) }
        #endif
        return SSHHostResolver.endpoint(of: host)
    }

    // A jump host's own reachability is not this Mac's to test, so it reads Online.
    nonisolated private static func isReachable(_ endpoint: SSHHostResolver.Endpoint) -> Bool {
        switch endpoint {
        case .proxied: return true
        case .direct(let hostname, let port):
            #if DEBUG
                if let bannerOverrideForTesting { return bannerOverrideForTesting(hostname, port) }
            #endif
            return answersSSH(hostname, port: port)
        }
    }

    // Blocking: reads only the server's greeting, which sshd sends before any authentication.
    nonisolated static func answersSSH(
        _ hostname: String, port: UInt16, connectTimeout: Int = connectTimeout,
        bannerTimeout: TimeInterval = bannerTimeout
    ) -> Bool {
        guard let port = NWEndpoint.Port(rawValue: port) else { return false }
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = connectTimeout
        let connection = NWConnection(
            host: NWEndpoint.Host(hostname), port: port, using: NWParameters(tls: nil, tcp: tcp))
        defer { connection.cancel() }
        final class Progress: @unchecked Sendable {
            private let lock = NSLock()
            private var ready = false
            private var ssh = false
            var isReady: Bool {
                get { lock.withLock { ready } }
                set { lock.withLock { ready = newValue } }
            }
            var isSSH: Bool {
                get { lock.withLock { ssh } }
                set { lock.withLock { ssh = newValue } }
            }
        }
        let progress = Progress()
        let connected = DispatchSemaphore(value: 0)
        let answered = DispatchSemaphore(value: 0)
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                progress.isReady = true
                connected.signal()
            case .waiting, .failed:
                connected.signal()
            default:
                break
            }
        }
        func read(after received: Data) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: maxGreetingLine) {
                data, _, isComplete, error in
                let buffer = received + (data ?? Data())
                if let verdict = greeting(in: buffer) {
                    progress.isSSH = verdict
                    answered.signal()
                    return
                }
                guard !isComplete, error == nil else {
                    answered.signal()
                    return
                }
                read(after: buffer)
            }
        }
        connection.start(queue: DispatchQueue(label: "ZenTerm.SSHHostProbe.connection"))
        _ = connected.wait(timeout: .now() + .seconds(connectTimeout))
        guard progress.isReady else { return false }
        read(after: Data())
        _ = answered.wait(timeout: .now() + bannerTimeout)
        return progress.isSSH
    }

    // RFC 4253 4.2: a server may send lines before its `SSH-` version line. Nil until the bytes decide it.
    nonisolated static func greeting(in data: Data) -> Bool? {
        var line = data[...]
        for _ in 0..<maxGreetingLines {
            if line.starts(with: banner) { return true }
            guard let newline = line.firstIndex(of: UInt8(ascii: "\n")) else {
                return line.count < maxGreetingLine ? nil : false
            }
            guard line.distance(from: line.startIndex, to: newline) < maxGreetingLine else { return false }
            line = line[line.index(after: newline)...]
        }
        return false
    }
}
