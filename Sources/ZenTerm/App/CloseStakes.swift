import ControlProtocol

struct CloseStakes: Equatable {
    let closesWindow: Bool
    var closesOtherWindows = 0
    let isRunning: Bool
    let panes: [ListResult.Pane]
    let floats: [String]
    var login: Login?

    var needsForce: Bool { closesWindow || closesOtherWindows > 0 || isRunning || login != nil }

    struct Login: Equatable {
        let host: String
        let tabs: Int
    }
}
