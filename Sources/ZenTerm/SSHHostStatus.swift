import AppKit

enum SSHHostStatus: Equatable {
    case offline
    case online
    case connected

    var isNavigable: Bool { self != .offline }

    // Offline and Connected borrow the agent row's idle and working inks, so the two lists read alike.
    var ink: NSColor {
        switch self {
        case .offline: return AttentionTone.idle.ink
        case .online: return Theme.current.chrome.positive.nsColor
        case .connected: return AttentionTone.working.ink
        }
    }
}
