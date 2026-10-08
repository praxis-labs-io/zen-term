import AppLog
import ControlProtocol
import Foundation

final class SocketListener {
    // Per pid: a shared path let a second instance bind over this one and delete it on quit.
    static func path(prefix: String) -> String {
        ControlEndpoint.directory.appendingPathComponent("\(prefix)\(getpid()).sock").path
    }

    // Probes liveness with a connect rather than a pid check, which pid recycling could fool.
    static func sweepStaleSockets(prefix: String, in directory: String) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return }
        for name in names where name.hasPrefix(prefix) && name.hasSuffix(".sock") {
            if pid_t(name.dropFirst(prefix.count).dropLast(".sock".count)) == getpid() { continue }
            let path = directory + "/" + name
            if !hasListener(at: path) { unlink(path) }
        }
    }

    // Answers live when the probe cannot run, so the sweep never deletes a file it did not check.
    private static func hasListener(at path: String) -> Bool {
        do {
            close(try UnixSocket.connect(to: path))
            return true
        } catch .connect {
            return false
        } catch {
            return true
        }
    }

    private static let socketMode: mode_t = 0o600
    private static let directoryMode = 0o700

    private let prefix: String
    private let path: String
    private let name: String
    private let category: LogCategory
    private let ownerUID: uid_t
    private let accept: (Int32) -> Void
    private let queue: DispatchQueue
    private var acceptSource: DispatchSourceRead?

    init(
        prefix: String, path: String? = nil, name: String, category: LogCategory, ownerUID: uid_t = geteuid(),
        accept: @escaping (Int32) -> Void
    ) {
        self.prefix = prefix
        self.path = path ?? Self.path(prefix: prefix)
        self.name = name
        self.category = category
        self.ownerUID = ownerUID
        self.accept = accept
        queue = DispatchQueue(label: "com.zenterm.\(name)-listener")
    }

    @discardableResult
    func start() -> Bool {
        stop()

        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: Self.directoryMode])

        if path == Self.path(prefix: prefix) {
            let prefix = prefix
            queue.async { Self.sweepStaleSockets(prefix: prefix, in: directory.path) }
        }

        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            Log.warning("\(name): socket() failed (\(errnoText())), listener disabled", category: category)
            return false
        }

        guard var addr = UnixSocket.address(for: path) else {
            Log.warning("\(name): socket path too long for sun_path: \(path), listener disabled", category: category)
            close(fd)
            return false
        }

        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, chmod(path, Self.socketMode) == 0, listen(fd, 8) == 0 else {
            Log.warning(
                "\(name): bind/listen on \(path) failed (\(errnoText())), listener disabled", category: category)
            close(fd)
            unlink(path)
            return false
        }

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptOne(listenFD: fd) }
        source.setCancelHandler { close(fd) }
        source.resume()
        acceptSource = source
        return true
    }

    func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        unlink(path)
    }

    private func acceptOne(listenFD: Int32) {
        let conn = Darwin.accept(listenFD, nil, nil)
        guard conn >= 0 else { return }
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(conn, &uid, &gid) == 0, uid == ownerUID else {
            Log.warning("\(name): refused a connection from uid \(uid)", category: category)
            close(conn)
            return
        }
        UnixSocket.disableSigpipe(on: conn)
        accept(conn)
    }

    private func errnoText() -> String {
        let code = errno
        var message = [CChar](repeating: 0, count: 256)
        strerror_r(code, &message, message.count)
        return "errno \(code): \(String(cString: message))"
    }

    deinit { stop() }
}
