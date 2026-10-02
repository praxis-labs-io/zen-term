import AppLog
import Foundation
import TerminalKit

// One host workspace's shared ssh connection: the login pane starts at once, every other surface waits for its socket.
@MainActor
final class SSHConnection {
    enum State: Equatable { case connecting, connected, failed }

    struct Watchers {
        var awaitSocket:
            (_ path: URL, _ ready: @escaping @MainActor () -> Void, _ appeared: @escaping @MainActor () -> Void) ->
                () -> Void
        var checkMaster: (_ host: SSHHostID, _ path: URL, _ found: @escaping @MainActor (pid_t?) -> Void) -> Void
        var awaitExit: (_ pid: pid_t, _ exited: @escaping @MainActor () -> Void) -> () -> Void
    }

    private struct Waiting {
        let id: SurfaceID
        weak var surface: TerminalSurface?
        let env: [String: String]
    }

    let host: SSHHostID
    let controlPath: URL
    private(set) var state: State = .connecting
    var onConnectedChange: ((Bool) -> Void)?
    var onLoginFailed: (() -> Void)?

    private let watchers: Watchers
    private var login: Waiting?
    private var isLoginReady = false
    private var waiting: [Waiting] = []
    private var stopWatching: (() -> Void)?
    private var isShutDown = false

    init(host: SSHHostID, controlPath: URL? = nil, watchers: Watchers = .live) {
        self.host = host
        self.controlPath = controlPath ?? SSHLaunch.controlPath(for: host)
        self.watchers = watchers
    }

    func start(_ surface: TerminalSurface, id: SurfaceID, env: [String: String]) {
        guard !isShutDown, state != .failed else { return }
        if state == .connected { return launch(surface, env: env) }
        if let login {
            guard login.id == id else { return waiting.append(Waiting(id: id, surface: surface, env: env)) }
            if isLoginReady { launch(surface, env: env) }
            return
        }
        login = Waiting(id: id, surface: surface, env: env)
        awaitSocket()
    }

    func release(_ ids: [SurfaceID]) {
        waiting.removeAll { ids.contains($0.id) }
        guard state == .connecting, let login, ids.contains(login.id) else { return }
        Log.info("ssh login ended before the connection came up", category: .workspace)
        state = .failed
        waiting = []
        self.login = nil
        stopWatching?()
        stopWatching = nil
        onLoginFailed?()
    }

    func shutdown() {
        guard !isShutDown else { return }
        isShutDown = true
        let wasConnected = state == .connected
        waiting = []
        login = nil
        stopWatching?()
        stopWatching = nil
        if wasConnected { onConnectedChange?(false) }
    }

    private func awaitSocket() {
        isLoginReady = false
        stopWatching = watchers.awaitSocket(
            controlPath,
            { [weak self] in self?.loginReady() },
            { [weak self] in self?.socketAppeared() })
    }

    private func loginReady() {
        guard !isShutDown, state == .connecting, let login else { return }
        isLoginReady = true
        if let surface = login.surface { launch(surface, env: login.env) }
    }

    private func socketAppeared() {
        guard !isShutDown, state == .connecting else { return }
        watchers.checkMaster(host, controlPath) { [weak self] pid in self?.masterFound(pid) }
    }

    private func masterFound(_ pid: pid_t?) {
        guard !isShutDown, state == .connecting else { return }
        Log.info("ssh connection up (master pid \(pid.map(String.init) ?? "unknown"))", category: .workspace)
        state = .connected
        login = nil
        stopWatching?()
        stopWatching = pid.map { watchers.awaitExit($0) { [weak self] in self?.masterExited() } }
        let flushing = waiting
        waiting = []
        for entry in flushing { entry.surface.map { launch($0, env: entry.env) } }
        onConnectedChange?(true)
    }

    private func masterExited() {
        guard !isShutDown, state == .connected else { return }
        Log.info("ssh connection ended", category: .workspace)
        state = .connecting
        stopWatching = nil
        onConnectedChange?(false)
    }

    private func launch(_ surface: TerminalSurface, env: [String: String]) {
        surface.start(SSHLaunch.config(host: host, controlPath: controlPath, env: env))
    }
}

extension SSHConnection.Watchers {
    private static let checkTimeout: TimeInterval = 5

    static let live = SSHConnection.Watchers(
        awaitSocket: { path, ready, appeared in
            let watch = ControlSocketWatch(path: path, ready: ready, appeared: appeared)
            return watch.cancel
        },
        checkMaster: { host, path, found in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Subprocess.run(
                    URL(fileURLWithPath: SSHLaunch.executable),
                    SSHLaunch.checkArguments(host: host, controlPath: path), timeout: checkTimeout)
                let pid = (try? result.get()).flatMap { SSHLaunch.masterPID(in: $0.stderr + "\n" + $0.stdout) }
                DispatchQueue.main.async { found(pid) }
            }
        },
        awaitExit: { pid, exited in
            let source = DispatchSource.makeProcessSource(
                identifier: pid, eventMask: .exit, queue: DispatchQueue.global(qos: .utility))
            source.setEventHandler {
                source.cancel()
                DispatchQueue.main.async { exited() }
            }
            source.resume()
            if kill(pid, 0) != 0, errno == ESRCH {
                source.cancel()
                DispatchQueue.main.async { exited() }
            }
            return { source.cancel() }
        })
}
