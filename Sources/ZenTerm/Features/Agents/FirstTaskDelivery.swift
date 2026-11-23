import ControlProtocol
import Foundation
import TerminalKit

final class FirstTaskDelivery {
    static let readinessWindow = TimeInterval(ControlWire.longestFirstTaskWait)

    private struct Pending {
        let send: () -> Void
        let settle: (FirstTask) -> Void
        let deadline: DispatchWorkItem
    }

    private var pending: [SurfaceID: Pending] = [:]
    private let readinessWindow: TimeInterval

    init(readinessWindow: TimeInterval = FirstTaskDelivery.readinessWindow) {
        self.readinessWindow = readinessWindow
    }

    func await(_ surface: SurfaceID, send: @escaping () -> Void, settle: @escaping (FirstTask) -> Void) {
        finish(surface, .held(.notReady))
        let deadline = DispatchWorkItem { [weak self] in self?.finish(surface, .held(.noStatus)) }
        pending[surface] = Pending(send: send, settle: settle, deadline: deadline)
        DispatchQueue.main.asyncAfter(deadline: .now() + readinessWindow, execute: deadline)
    }

    func isAwaiting(_ surface: SurfaceID) -> Bool { pending[surface] != nil }

    func report(_ status: TerminalProgramStatus, from surface: SurfaceID) {
        guard let waiting = pending[surface] else { return }
        let outcome = Self.outcome(of: status)
        if outcome.sent { waiting.send() }
        finish(surface, outcome)
    }

    func release(_ surface: SurfaceID) { finish(surface, .held(.notReady)) }

    private func finish(_ surface: SurfaceID, _ outcome: FirstTask) {
        guard let waiting = pending.removeValue(forKey: surface) else { return }
        waiting.deadline.cancel()
        waiting.settle(outcome)
    }

    // Only a program waiting for input takes a task: one mid-turn or failing would lose it.
    private static func outcome(of status: TerminalProgramStatus) -> FirstTask {
        switch status.state {
        case .idle, .done: return .delivered
        case .blocked: return .held(.blocked)
        case .working, .failed: return .held(.notReady)
        }
    }
}
