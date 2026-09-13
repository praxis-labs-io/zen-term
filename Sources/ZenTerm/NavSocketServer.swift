import AppLog
import Foundation

/// A `setvim` hold clears when its connection closes, since the kernel closes the fd however nvim dies.
final class NavSocketServer {
    /// Per pid: a shared path let a second instance bind over this one and delete it on quit.
    static var socketURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ZenTerm", isDirectory: true)
        return base.appendingPathComponent("nav.\(getpid()).sock")
    }
    static var socketPath: String { socketURL.path }

    /// Probes liveness with a connect rather than a pid check, which pid recycling could fool.
    static func sweepStaleSockets(in directory: String) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return }
        for name in names where name.hasPrefix("nav.") && name.hasSuffix(".sock") {
            if pid_t(name.dropFirst("nav.".count).dropLast(".sock".count)) == getpid() { continue }
            let path = directory + "/" + name
            if !hasListener(at: path) { unlink(path) }
        }
    }

    /// Answers live when the probe cannot run, so the sweep never deletes a file it did not check.
    private static func hasListener(at path: String) -> Bool {
        guard var addr = socketAddress(for: path) else { return true }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return true }
        defer { close(fd) }
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return connected == 0
    }

    private static func socketAddress(for path: String) -> sockaddr_un? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count < capacity else { return nil }
        withUnsafeMutablePointer(to: &addr.sun_path) {
            $0.withMemoryRebound(to: UInt8.self, capacity: capacity) { dst in
                for (i, byte) in pathBytes.enumerated() { dst[i] = byte }
                dst[pathBytes.count] = 0
            }
        }
        return addr
    }

    static func env(token: Int) -> [String: String] {
        ["ZEN_SOCK": socketPath, "ZEN_PANE": String(token)]
    }

    static func env(base: [String: String], token: Int) -> [String: String] {
        base.merging(env(token: token)) { _, new in new }
    }

    private let apply: (NavCommand) -> Void
    private let path: String
    private let recvTimeout: time_t
    private let queue = DispatchQueue(label: "com.zenterm.nav-socket")
    /// Its own queue: a held connection parks a thread for the life of an nvim.
    private let connections = DispatchQueue(
        label: "com.zenterm.nav-connections", qos: .utility, attributes: .concurrent)
    private var acceptSource: DispatchSourceRead?

    init(
        path: String = NavSocketServer.socketPath, recvTimeout: time_t = 2,
        apply: @escaping (NavCommand) -> Void
    ) {
        self.path = path
        self.recvTimeout = recvTimeout
        self.apply = apply
    }

    func start() {
        stop()

        try? FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)

        if path == Self.socketPath {
            let directory = URL(fileURLWithPath: path).deletingLastPathComponent().path
            queue.async { Self.sweepStaleSockets(in: directory) }
        }

        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            Log.warning(
                "NavSocket: socket() failed (\(errnoText())) — seamless nav disabled", category: .nav)
            return
        }

        guard var addr = Self.socketAddress(for: path) else {
            Log.warning(
                "NavSocket: socket path too long for sun_path: \(path) — seamless nav disabled",
                category: .nav)
            close(fd)
            return
        }

        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(fd, 8) == 0 else {
            Log.warning(
                "NavSocket: bind/listen on \(path) failed (\(errnoText())) — seamless nav disabled",
                category: .nav)
            close(fd)
            return
        }

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptOne(listenFD: fd) }
        source.setCancelHandler { close(fd) }
        source.resume()
        acceptSource = source
    }

    private func errnoText() -> String { "errno \(errno): \(String(cString: strerror(errno)))" }

    func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        unlink(path)
    }

    private func acceptOne(listenFD: Int32) {
        let conn = accept(listenFD, nil, nil)
        guard conn >= 0 else { return }
        Self.setRecvTimeout(recvTimeout, on: conn)
        connections.async { [weak self] in
            guard let self else {
                close(conn)
                return
            }
            self.readConnection(conn)
        }
    }

    private static func setRecvTimeout(_ seconds: time_t, on fd: Int32) {
        var timeout = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    private func readConnection(_ fd: Int32) {
        var heldTokens: Set<Int> = []
        defer {
            close(fd)
            for token in heldTokens.sorted() {
                Log.info("NavSocket: connection closed, clearing pane=\(token)", category: .nav)
                DispatchQueue.main.async { [weak self] in
                    self?.apply(.setVim(token: token, presence: .off))
                }
            }
        }
        var pending = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { break }
            pending.append(contentsOf: chunk[0..<n])
            while let newline = pending.firstIndex(of: 0x0A) {
                let command = dispatch(pending[pending.startIndex..<newline])
                pending.removeSubrange(pending.startIndex...newline)
                guard case .setVim(let token, let presence) = command else { continue }
                switch presence {
                case .held:
                    Self.setRecvTimeout(0, on: fd)
                    heldTokens.insert(token)
                case .off, .latched:
                    heldTokens.remove(token)
                }
                if heldTokens.isEmpty { Self.setRecvTimeout(recvTimeout, on: fd) }
            }
            if pending.count > 64 * 1024 { pending.removeAll(keepingCapacity: false) }
        }
    }

    @discardableResult
    private func dispatch(_ lineData: Data) -> NavCommand? {
        guard let line = String(data: lineData, encoding: .utf8),
            let command = NavCommand.decode(line)
        else { return nil }
        Log.info("NavSocket: \(command.logLine)", category: .nav)
        DispatchQueue.main.async { [weak self] in self?.apply(command) }
        return command
    }

    deinit { stop() }
}
