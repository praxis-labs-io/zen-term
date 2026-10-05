import AppKit
import AppLog
import Network

// Keeps each SSH host's reachability current by connecting to its ssh port and reading the banner, never logging in.
@MainActor
final class SSHHostProbe {
    enum Answer: String {
        case reachable = "reachable"
        case proxied = "proxied, not connected to"
        case bannerMissing = "banner missing"
        case connectFailed = "connect failed or timed out"
        case resolveFailed = "resolve failed"
        case networkDown = "network down, not connected to"

        // A jump host's own reachability is not this Mac's to test, so it reads Online.
        var isReachable: Bool { self == .reachable || self == .proxied }
    }

    #if DEBUG
        nonisolated(unsafe) static var resolveOverrideForTesting: ((String) -> SSHHostResolver.Resolution?)?
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
    private var resolutions: [String: SSHHostResolver.Resolution] = [:]
    private var configStamp: [String: Date]?
    private var inFlight: Set<String> = []
    private var generation = 0
    private var isNetworkUp = true
    private var isStarted = false
    private var isSeeded = false
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
        guard !isSeeded || next != hosts else { return }
        isSeeded = true
        let previous = hosts
        hosts = next
        for host in previous where !next.contains(host) {
            proxied.remove(host)
            resolutions[host] = nil
            center.setReachable(false, host: SSHHostID(alias: host))
            center.setDestination(nil, host: SSHHostID(alias: host))
        }
        refreshWatching()
        probe(next.filter { !previous.contains($0) })
    }

    func probeAll() { probe(hosts) }

    func networkChanged(isUp: Bool) {
        generation += 1
        isNetworkUp = isUp
        resolutions = [:]
        pendingSettle?.cancel()
        guard isUp else {
            for host in hosts where !proxied.contains(host) {
                center.setReachable(false, host: SSHHostID(alias: host))
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

    // A round first reads the ssh config's file dates off-main, since an edit there can move a host.
    private func probe(_ targets: [String]) {
        Self.queue.addOperation { [weak self] in
            let stamp = Self.readConfigStamp()
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.probe(targets, configStamp: stamp) }
            }
        }
    }

    // Without a network only `ssh -G` runs, so a jump host still learns it is one.
    private func probe(_ targets: [String], configStamp stamp: [String: Date]) {
        if stamp != configStamp {
            resolutions = [:]
            configStamp = stamp
        }
        resolveConnectedHosts()
        let isNetworkUp = self.isNetworkUp
        for host in targets
        where hosts.contains(host) && !inFlight.contains(host)
            && center.status(of: SSHHostID(alias: host)) != .connected
        {
            inFlight.insert(host)
            let generation = self.generation
            let cached = resolutions[host]
            Self.queue.addOperation { [weak self] in
                let resolution = cached ?? Self.resolve(host)
                let answer = Self.answer(resolution?.endpoint, isNetworkUp: isNetworkUp)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.land(
                            answer, from: resolution, for: host, generation: generation, isNetworkUp: isNetworkUp)
                    }
                }
            }
        }
    }

    private func resolveConnectedHosts() {
        for host in hosts
        where !inFlight.contains(host) && resolutions[host] == nil
            && center.status(of: SSHHostID(alias: host)) == .connected
        {
            inFlight.insert(host)
            let generation = self.generation
            Self.queue.addOperation { [weak self] in
                let resolution = Self.resolve(host)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.land(resolution, forConnected: host, generation: generation)
                    }
                }
            }
        }
    }

    private func land(_ resolution: SSHHostResolver.Resolution?, forConnected host: String, generation: Int) {
        inFlight.remove(host)
        guard hosts.contains(host) else { return }
        guard generation == self.generation else { return probe([host]) }
        resolutions[host] = resolution
        center.setDestination(resolution?.destination, host: SSHHostID(alias: host))
        if center.status(of: SSHHostID(alias: host)) != .connected { probe([host]) }
    }

    // An answer from before a network change describes the old network, so the host is asked again.
    private func land(
        _ answer: Answer, from resolution: SSHHostResolver.Resolution?, for host: String, generation: Int,
        isNetworkUp: Bool
    ) {
        inFlight.remove(host)
        let endpoint = resolution?.endpoint
        let isStale = generation != self.generation
        Log.info(
            "ssh probe \(host) at \(Self.describe(endpoint)), network \(isNetworkUp ? "up" : "down"), "
                + "generation \(generation): \(answer.rawValue)\(isStale ? ", stale, asking again" : "")",
            category: .workspace)
        guard hosts.contains(host) else { return }
        guard !isStale else { return probe([host]) }
        resolutions[host] = resolution
        if endpoint == .proxied { proxied.insert(host) } else { proxied.remove(host) }
        center.setReachable(answer.isReachable, host: SSHHostID(alias: host))
        center.setDestination(resolution?.destination, host: SSHHostID(alias: host))
    }

    private static func describe(_ endpoint: SSHHostResolver.Endpoint?) -> String {
        switch endpoint {
        case .direct(let hostname, let port): return "\(hostname):\(port)"
        case .proxied: return "a proxy"
        case nil: return "no endpoint"
        }
    }

    nonisolated private static func readConfigStamp() -> [String: Date] {
        var stamp: [String: Date] = [:]
        for path in SSHConfigFiles.paths(of: SSHConfigFiles.userConfig) {
            stamp[path] = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        }
        return stamp
    }

    nonisolated private static func resolve(_ host: String) -> SSHHostResolver.Resolution? {
        #if DEBUG
            if let resolveOverrideForTesting { return resolveOverrideForTesting(host) }
        #endif
        return SSHHostResolver.resolution(of: host)
    }

    nonisolated private static func answer(_ endpoint: SSHHostResolver.Endpoint?, isNetworkUp: Bool) -> Answer {
        switch endpoint {
        case nil: return .resolveFailed
        case .proxied: return .proxied
        case .direct where !isNetworkUp: return .networkDown
        case .direct(let hostname, let port):
            #if DEBUG
                if let bannerOverrideForTesting {
                    return bannerOverrideForTesting(hostname, port) ? .reachable : .bannerMissing
                }
            #endif
            return answersSSH(hostname, port: port)
        }
    }

    // Blocking: reads only the server's greeting, which sshd sends before any authentication.
    nonisolated static func answersSSH(
        _ hostname: String, port: UInt16, connectTimeout: Int = connectTimeout,
        bannerTimeout: TimeInterval = bannerTimeout
    ) -> Answer {
        guard let port = NWEndpoint.Port(rawValue: port) else { return .connectFailed }
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
        guard progress.isReady else { return .connectFailed }
        read(after: Data())
        _ = answered.wait(timeout: .now() + bannerTimeout)
        return progress.isSSH ? .reachable : .bannerMissing
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
