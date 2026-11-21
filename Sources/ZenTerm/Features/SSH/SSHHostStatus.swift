import AppKit

enum SSHHostStatus: Equatable {
    case offline
    case online
    case connected

    var word: String {
        switch self {
        case .offline: return "Offline"
        case .online: return "Online"
        case .connected: return "Connected"
        }
    }

    var isNavigable: Bool { self == .connected }

    // Offline and Connected match the agent row's idle and working inks, so the two lists read alike.
    var ink: NSColor {
        let chrome = Theme.current.chrome
        switch self {
        case .offline: return chrome.ink(.muted)
        case .online: return chrome.positive.nsColor
        case .connected: return chrome.working.nsColor
        }
    }
}
