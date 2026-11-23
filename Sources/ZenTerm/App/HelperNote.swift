import ControlProtocol

// What a parent agent hears when a helper `pane.run` started stops, blocks or exits.
struct HelperNote: Equatable {
    enum Change: Equatable {
        case stopped(ListResult.AgentStatus?)
        case blocked(ListResult.AgentNeed?)
        case exited(code: Int?)
    }

    let helper: Int
    let name: String?
    let parent: Int
    let change: Change
    let answeredWaits: Set<SurfaceID>

    // An exit closes the helper's pane, so only its note still means something once the pane is gone.
    var outlivesHelper: Bool {
        if case .exited = change { return true }
        return false
    }

    var text: String {
        let who = name.map(ZenEnvelope.escaped) ?? "pane \(helper)"
        switch change {
        case .stopped(let status):
            let word = status.map { " (\($0.rawValue))" } ?? ""
            return "\(who) stopped\(word): read it with zen pane read --pane \(helper)"
        case .blocked(let need):
            return "\(who) is blocked\(need.map { " on \(Self.waitsOn($0))" } ?? ""); that decision is the user's"
        case .exited(let code):
            return "\(who) exited\(code.map { " with code \($0)" } ?? "")"
        }
    }

    private static func waitsOn(_ need: ListResult.AgentNeed) -> String {
        switch need {
        case .permission: return "a permission prompt"
        case .question: return "a question"
        case .auth: return "a login"
        }
    }
}
