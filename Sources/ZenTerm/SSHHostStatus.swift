enum SSHHostStatus: Equatable {
    case offline
    case online
    case connected

    var isNavigable: Bool { self != .offline }
}
