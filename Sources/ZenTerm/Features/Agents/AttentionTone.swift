// One agent's state, shown by its Agents row and its tab.
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
        case .idle: return .idle
        case .working: return nil
        }
    }
}
