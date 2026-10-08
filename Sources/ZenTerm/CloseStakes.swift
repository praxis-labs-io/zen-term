import ControlProtocol

/// What closing a tab or workspace would end. `isRunning` is the reading the close confirmations use.
struct CloseStakes: Equatable {
    let closesWindow: Bool
    let isRunning: Bool
    let panes: [ListResult.Pane]
    let floats: [String]
    var login: Login?

    var needsForce: Bool { closesWindow || isRunning || login != nil }

    struct Login: Equatable {
        let host: String
        let tabs: Int
    }
}
