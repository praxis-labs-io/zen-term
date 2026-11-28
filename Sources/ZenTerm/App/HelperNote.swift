import ControlProtocol

// What a parent agent hears when a helper `pane.run` started stops, blocks or exits.
struct HelperNote: Equatable {
    enum Change: Equatable {
        case stopped(ListResult.AgentStatus?)
        case blocked(ListResult.AgentNeed?)
        case resumed
        case exited(code: Int?, outputFile: String?)
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
        case .blocked(.question):
            return "\(who) is asking a question: read it with zen pane read --pane \(helper) and answer it, "
                + "or ask the user when it is a product or scope call"
        case .blocked(.permission):
            return "\(who) is blocked on a permission prompt; that decision is the user's"
        case .blocked(.auth):
            return "\(who) is blocked on a login; that decision is the user's"
        case .blocked(nil):
            return "\(who) is blocked; that decision is the user's"
        case .resumed:
            return "\(who) is working again; wait on it with zen wait \(helper)"
        case .exited(let code, let outputFile):
            let withCode = code.map { " with code \($0)" } ?? ""
            return "\(who) exited\(withCode)\(outputFile.map { ", output in \($0)" } ?? "")"
        }
    }
}
