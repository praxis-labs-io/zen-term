import AppLog
import Foundation

/// A `setvim` hold clears when its connection closes, since the kernel closes the fd however nvim dies.
final class NavSocketServer {
    static let prefix = "nav."

    static var socketPath: String { SocketListener.path(prefix: prefix) }

    static func sweepStaleSockets(in directory: String) {
        SocketListener.sweepStaleSockets(prefix: prefix, in: directory)
    }

    static func env(token: Int) -> [String: String] {
        ["ZEN_SOCK": socketPath, "ZEN_PANE": String(token)]
    }

    private let apply: (NavCommand) -> Void
    private let recvTimeout: time_t
    /// Its own queue: a held connection parks a thread for the life of an nvim.
    private let connections = DispatchQueue(
        label: "com.zenterm.nav-connections", qos: .utility, attributes: .concurrent)
    private var listener: SocketListener?

    init(
        path: String = NavSocketServer.socketPath, recvTimeout: time_t = 2,
        apply: @escaping (NavCommand) -> Void
    ) {
        self.recvTimeout = recvTimeout
        self.apply = apply
        listener = SocketListener(prefix: Self.prefix, path: path, name: "NavSocket", category: .nav) {
            [weak self] conn in self?.acceptOne(conn)
        }
    }

    func start() { listener?.start() }

    func stop() { listener?.stop() }

    private func acceptOne(_ conn: Int32) {
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
}
