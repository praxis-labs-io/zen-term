import AppLog
import Foundation

// Waits, off-main, for an ssh control socket to appear by watching its folder for writes rather than polling.
final class ControlSocketWatch: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.zenterm.ssh-control-socket")
    private let path: URL
    private let appeared: @MainActor () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var isCancelled = false

    init(
        path: URL, ready: @escaping @MainActor () -> Void, appeared: @escaping @MainActor () -> Void,
        unwatchable: @escaping @MainActor () -> Void
    ) {
        self.path = path
        self.appeared = appeared
        queue.async { [self] in
            guard arm() else {
                if !isCancelled { DispatchQueue.main.async { unwatchable() } }
                return
            }
            DispatchQueue.main.async { ready() }
            check()
        }
    }

    func cancel() {
        queue.async { [self] in stop() }
    }

    private func arm() -> Bool {
        let folder = path.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            Log.error("ssh: couldn't create \(folder.path): \(error)", category: .workspace)
        }
        guard !isCancelled else { return true }
        let descriptor = open(folder.path, O_EVTONLY)
        guard descriptor >= 0 else {
            Log.error("ssh: couldn't watch \(folder.path) for the control socket", category: .workspace)
            return false
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: .write, queue: queue)
        source.setEventHandler { [weak self] in self?.check() }
        source.setCancelHandler { close(descriptor) }
        self.source = source
        source.resume()
        return true
    }

    private func check() {
        guard !isCancelled, FileManager.default.fileExists(atPath: path.path) else { return }
        stop()
        let appeared = appeared
        DispatchQueue.main.async { appeared() }
    }

    private func stop() {
        isCancelled = true
        source?.cancel()
        source = nil
    }
}
