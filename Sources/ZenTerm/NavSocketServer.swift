import Foundation

/// A tiny `AF_UNIX` stream listener that carries the nvim navigator protocol. Neovim
/// connects natively via `sockconnect('pipe', $ZEN_SOCK)` and writes one newline-delimited
/// JSON line (`NavCommand`) per hop — no process spawn per keystroke. Each connection is
/// short-lived: read the line(s), decode, hand the command to `apply` on the main actor,
/// close.
///
/// Kept deliberately small: a listen socket + a `DispatchSource` that accepts, plus a
/// bounded read per connection. The wire format and all routing live elsewhere
/// (`NavCommand`, `NavRegistry`).
final class NavSocketServer {
    /// `~/Library/Application Support/ZenTerm/nav.sock`. Exported to panes as `$ZEN_SOCK`.
    static var socketURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ZenTerm", isDirectory: true)
        return base.appendingPathComponent("nav.sock")
    }
    static var socketPath: String { socketURL.path }

    /// Applied on the main actor for every decoded command.
    private let apply: (NavCommand) -> Void
    /// The bound socket path. Defaults to the shared `$ZEN_SOCK` location; overridden in
    /// tests so they never touch the real socket.
    private let path: String
    private let queue = DispatchQueue(label: "com.zenterm.nav-socket")
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?

    init(path: String = NavSocketServer.socketPath, apply: @escaping (NavCommand) -> Void) {
        self.path = path
        self.apply = apply
    }

    /// Bind the socket and start accepting. Removes a stale socket file first (a prior run
    /// that didn't clean up), so a relaunch always rebinds. Silently no-ops on failure —
    /// the ⌘-nav path never depends on this, so a socket that can't bind just leaves the
    /// seamless-nav opt-in inert.
    func start() {
        stop()

        try? FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
        unlink(path)  // clear a stale socket from a prior run

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count < capacity else { close(fd); return }  // leave room for NUL
        withUnsafeMutablePointer(to: &addr.sun_path) {
            $0.withMemoryRebound(to: UInt8.self, capacity: capacity) { dst in
                for (i, byte) in pathBytes.enumerated() { dst[i] = byte }
                dst[pathBytes.count] = 0
            }
        }

        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(fd, 8) == 0 else { close(fd); return }
        listenFD = fd

        // The source owns the listen fd: it's closed in the cancel handler (which runs on
        // `queue` after the last accept), so `stop()` on the main thread never races the
        // accept handler over the descriptor.
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptOne() }
        source.setCancelHandler { [weak self] in
            close(fd)
            self?.listenFD = -1
        }
        source.resume()
        acceptSource = source
    }

    /// Stop accepting and remove the file so the next launch rebinds. The listen fd is closed
    /// by the source's cancel handler, not here, to keep all fd access on `queue`.
    func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        unlink(path)
    }

    private func acceptOne() {
        let conn = accept(listenFD, nil, nil)
        guard conn >= 0 else { return }
        // A wedged client must not stall the accept queue: bound the read, then read off the
        // shared concurrent queue so one slow connection can't head-of-line the rest. Close
        // the connection even if `self` is gone by the time the read block runs.
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(conn, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else {
                close(conn)
                return
            }
            self.readConnection(conn)
        }
    }

    private func readConnection(_ fd: Int32) {
        defer { close(fd) }
        var pending = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { break }
            pending.append(contentsOf: chunk[0..<n])
            // Dispatch each complete line as it arrives, so a client that holds the channel
            // open (rather than closing after one line) sees no EOF/timeout latency.
            while let newline = pending.firstIndex(of: 0x0A) {
                dispatch(pending[pending.startIndex..<newline])
                pending.removeSubrange(pending.startIndex...newline)
            }
            // A single unterminated line grown past the cap is junk (never a nav command):
            // drop it rather than buffer unboundedly or later decode a truncated tail.
            if pending.count > 64 * 1024 { pending.removeAll(keepingCapacity: false) }
        }
    }

    private func dispatch(_ lineData: Data) {
        guard let line = String(data: lineData, encoding: .utf8),
            let command = NavCommand.decode(line)
        else { return }
        DispatchQueue.main.async { [weak self] in self?.apply(command) }
    }

    deinit { stop() }
}
