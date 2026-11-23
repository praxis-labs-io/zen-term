import TerminalKit

// A task submitted to a ready agent shows no change until the agent reports again.
final class TaskPickups {
    private var awaiting: Set<SurfaceID> = []

    func submitted(to surface: SurfaceID) { awaiting.insert(surface) }

    // A report of the readiness the task was sent on is not a pickup.
    func report(_ status: TerminalProgramStatus, from surface: SurfaceID) {
        if !Self.isReady(status) { awaiting.remove(surface) }
    }

    func awaitsPickup(_ surface: SurfaceID) -> Bool { awaiting.contains(surface) }

    func release(_ surface: SurfaceID) { awaiting.remove(surface) }

    static func isReady(_ status: TerminalProgramStatus) -> Bool {
        switch status.state {
        case .idle, .done: return true
        case .blocked, .working, .failed: return false
        }
    }
}
