enum SSHHostStatus: Equatable {
    case offline
    case online
    case connecting
    case connected

    var word: String {
        switch self {
        case .offline: return "Offline"
        case .online: return "Online"
        case .connecting: return "Connecting"
        case .connected: return "Connected"
        }
    }

    var isNavigable: Bool { self == .connected }
}
