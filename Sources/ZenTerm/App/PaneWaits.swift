import ControlProtocol
import Foundation

// App-wide, since a wait's caller and the pane it waits on can sit in different windows. Main-thread only.
final class PaneWaits {
    private(set) var pending: [PaneWait] = []

    func hold(_ wait: PaneWait, timeout: TimeInterval, hangup: ControlHangup) {
        pending.append(wait)
        wait.onAnswered = { [weak self, weak wait] in self?.pending.removeAll { $0 === wait } }
        hangup.onHangup { [weak wait] in wait?.cancel() }
        wait.start(timeout: timeout)
    }

    func agentStopped(_ surface: SurfaceID) { waits(on: surface).forEach { $0.agentStopped() } }

    func commandFinished(_ surface: SurfaceID, exitCode: Int?) {
        waits(on: surface).forEach { $0.commandFinished(exitCode: exitCode) }
    }

    func panesClosed(_ surfaces: [SurfaceID]) {
        let closed = Set(surfaces)
        pending.filter { closed.contains($0.watched.surfaceID) }.forEach { $0.closed() }
    }

    func sent(to surface: SurfaceID) { pending.filter { $0.caller == surface }.forEach { $0.messageArrived() } }

    private func waits(on surface: SurfaceID) -> [PaneWait] { pending.filter { $0.watched.surfaceID == surface } }
}
