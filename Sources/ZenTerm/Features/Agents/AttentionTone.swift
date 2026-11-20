// One agent's state. The Agents list shows every case; tabs and rows show only `blocked` and `done`.
enum AttentionTone {
    case blocked, done, working, idle

    init(wait: AttentionStore.AgentWait?, working: Bool) {
        switch wait {
        case .ask: self = .blocked
        case .turnEnd: self = .done
        case nil: self = working ? .working : .idle
        }
    }

    var isWaiting: Bool { self == .blocked || self == .done }

    var dot: StateDot.State? {
        switch self {
        case .blocked: return .blocked
        case .done: return .done
        case .working, .idle: return nil
        }
    }
}

extension AttentionStore.AgentWait {
    var dot: StateDot.State {
        switch self {
        case .ask: return .blocked
        case .turnEnd: return .done
        }
    }
}
