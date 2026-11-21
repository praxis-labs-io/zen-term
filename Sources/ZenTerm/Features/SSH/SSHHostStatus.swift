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
}
