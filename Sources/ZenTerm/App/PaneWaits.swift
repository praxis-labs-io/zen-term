import ControlProtocol
import Foundation

// App-wide, since a wait's caller and the pane it waits on can sit in different windows. Main-thread only.
final class PaneWaits {
    private(set) var pending: [PaneWait] = []
    private(set) var childrenWaits: [ChildrenWait] = []
    var onPendingChanged: (() -> Void)?

    var waitedSurfaces: Set<SurfaceID> { Set(pending.map(\.watched.surfaceID)) }

    func hold(_ wait: PaneWait, timeout: TimeInterval, hangup: ControlHangup) {
        track(wait)
        hangup.onHangup { [weak wait] in wait?.cancel() }
        wait.start(timeout: timeout)
    }

    func hold(_ wait: ChildrenWait, timeout: TimeInterval, hangup: ControlHangup) {
        childrenWaits.append(wait)
        wait.onAnswered = { [weak self, weak wait] in self?.childrenWaits.removeAll { $0 === wait } }
        hangup.onHangup { [weak wait] in wait?.cancel() }
        wait.probes.forEach(track)
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

    func sent(to surface: SurfaceID, from sender: Int?) {
        pending.filter { $0.caller == surface }.forEach { $0.messageArrived(from: sender) }
        childrenWaits.filter { $0.caller == surface }.forEach { $0.messageArrived(from: sender) }
    }

    private func track(_ wait: PaneWait) {
        pending.append(wait)
        wait.onAnswered = { [weak self, weak wait] in
            self?.pending.removeAll { $0 === wait }
            self?.onPendingChanged?()
        }
        onPendingChanged?()
    }

    func callers(answeredBy reason: WaitReason, on surface: SurfaceID) -> Set<SurfaceID> {
        let children = childrenWaits.filter { $0.answers(reason, from: surface) }.map(\.caller)
        return Set(waits(on: surface).filter { $0.answers(reason) }.compactMap(\.caller) + children)
    }

    func callers(watching surface: SurfaceID) -> Set<SurfaceID> {
        let children = childrenWaits.filter { $0.watches(surface) }.map(\.caller)
        return Set(waits(on: surface).compactMap(\.caller) + children)
    }

    private func waits(on surface: SurfaceID) -> [PaneWait] { pending.filter { $0.watched.surfaceID == surface } }
}
