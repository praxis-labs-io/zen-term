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
        var resolveMaster: (_ host: SSHHostID, _ path: URL, _ found: @escaping @MainActor (pid_t?) -> Void) -> Void
        var awaitExit: (_ pid: pid_t, _ exited: @escaping @MainActor () -> Void) -> () -> Void
        var after: (_ delay: TimeInterval, _ work: @escaping @MainActor () -> Void) -> Void
    }

    // A socket that answers no check would otherwise re-fire its watch at once and spin `ssh -O check`.
    static let recheckDelay: TimeInterval = 1
    static let checksBeforeGivingUp = 3

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
    private var isLoginLaunched = false
    private var waiting: [Waiting] = []
    private var stopWatching: (() -> Void)?
    private var isShutDown = false
    private var failedChecks = 0

    #if DEBUG
        static var watchersOverrideForTesting: Watchers?
    #endif

    init(host: SSHHostID, controlPath: URL? = nil, watchers: Watchers? = nil) {
        self.host = host
        self.controlPath = controlPath ?? SSHLaunch.controlPath(for: host)
        #if DEBUG
            self.watchers = watchers ?? Self.watchersOverrideForTesting ?? .live
        #else
            self.watchers = watchers ?? .live
        #endif
    }

    func start(_ surface: TerminalSurface, id: SurfaceID, env: [String: String]) {
        guard !isShutDown, state != .failed else { return }
        if state == .connected { return launch(surface, env: env) }
        if let login {
            guard login.id == id else { return waiting.append(Waiting(id: id, surface: surface, env: env)) }
            if isLoginLaunched { launch(surface, env: env) }
            return
        }
        login = Waiting(id: id, surface: surface, env: env)
        isLoginLaunched = false
        watchers.resolveMaster(host, controlPath) { [weak self] pid in self?.resolvedBeforeLogin(pid) }
    }

    func isAwaitingLogin(on id: SurfaceID?) -> Bool {
        guard let id, state == .connecting, !isShutDown else { return false }
        return login?.id == id
    }

    func release(_ ids: [SurfaceID]) {
        waiting.removeAll { ids.contains($0.id) }
        guard state == .connecting, let login, ids.contains(login.id) else { return }
        fail("ssh login ended before the connection came up")
    }

    private func fail(_ reason: String) {
        Log.info(reason, category: .workspace)
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

    private func resolvedBeforeLogin(_ pid: pid_t?) {
        guard !isShutDown, state == .connecting, login != nil else { return }
        guard let pid else { return awaitSocket() }
        masterFound(pid)
    }

    private func awaitSocket() {
        stopWatching = watchers.awaitSocket(
            controlPath,
            { [weak self] in self?.loginReady() },
            { [weak self] in self?.socketAppeared() })
    }

    private func loginReady() {
        guard !isShutDown, state == .connecting, let login, !isLoginLaunched else { return }
        isLoginLaunched = true
        if let surface = login.surface { launch(surface, env: login.env) }
    }

    private func socketAppeared() {
        guard !isShutDown, state == .connecting else { return }
        watchers.resolveMaster(host, controlPath) { [weak self] pid in self?.resolvedOnSocket(pid) }
    }

    private func resolvedOnSocket(_ pid: pid_t?) {
        guard !isShutDown, state == .connecting else { return }
        guard let pid else { return recheckLater() }
        masterFound(pid)
    }

    private func recheckLater() {
        stopWatching?()
        stopWatching = nil
        failedChecks += 1
        guard failedChecks < Self.checksBeforeGivingUp else {
            return fail("ssh: no master answered on \(controlPath.path) after \(failedChecks) checks")
        }
        watchers.after(Self.recheckDelay) { [weak self] in
            guard let self, !self.isShutDown, self.state == .connecting else { return }
            self.awaitSocket()
        }
    }

    private func masterFound(_ pid: pid_t) {
        Log.info("ssh connection up (master pid \(pid))", category: .workspace)
        state = .connected
        failedChecks = 0
        let unlaunchedLogin = isLoginLaunched ? nil : login
        login = nil
        stopWatching?()
        stopWatching = watchers.awaitExit(pid) { [weak self] in self?.masterExited() }
        let flushing = (unlaunchedLogin.map { [$0] } ?? []) + waiting
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

    // A refused connect is the one answer that proves no master is listening; anything else leaves the socket alone.
    nonisolated static func master(of host: SSHHostID, at path: URL) -> pid_t? {
        guard FileManager.default.fileExists(atPath: path.path),
            case .success(let output) = Subprocess.run(
                URL(fileURLWithPath: SSHLaunch.executable),
                SSHLaunch.checkArguments(host: host, controlPath: path), timeout: checkTimeout)
        else { return nil }
        if let pid = SSHLaunch.masterPID(in: output.stderr + "\n" + output.stdout) { return pid }
        guard output.stderr.contains("Connection refused") else { return nil }
        Log.info("ssh: removing a control socket no master answers on", category: .workspace)
        unlink(path.path)
        return nil
    }

    static let live = SSHConnection.Watchers(
        awaitSocket: { path, ready, appeared in
            let watch = ControlSocketWatch(path: path, ready: ready, appeared: appeared)
            return watch.cancel
        },
        resolveMaster: { host, path, found in
            DispatchQueue.global(qos: .userInitiated).async {
                let pid = master(of: host, at: path)
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
        },
        after: { delay, work in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { work() }
        })
}
