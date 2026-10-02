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
    // Path updates arrive in bursts while an interface comes up.
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
        observe(workspace, NSWorkspace.didWakeNotification) { $0.probeAll() }
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

    // Blocking: reads only the server's banner, which sshd sends before any authentication.
    nonisolated private static func answersSSH(_ hostname: String, port: UInt16) -> Bool {
        guard let port = NWEndpoint.Port(rawValue: port) else { return false }
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = connectTimeout
        let connection = NWConnection(
            host: NWEndpoint.Host(hostname), port: port, using: NWParameters(tls: nil, tcp: tcp))
        let lock = NSLock()
        var isSSH = false
        let settled = DispatchSemaphore(value: 0)
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                connection.receive(minimumIncompleteLength: banner.count, maximumLength: banner.count) {
                    data, _, _, _ in
                    lock.withLock { isSSH = data == banner }
                    settled.signal()
                }
            case .waiting, .failed:
                settled.signal()
            default:
                break
            }
        }
        connection.start(queue: DispatchQueue(label: "ZenTerm.SSHHostProbe.connection"))
        _ = settled.wait(timeout: .now() + .seconds(connectTimeout))
        connection.cancel()
        return lock.withLock { isSSH }
    }
}
