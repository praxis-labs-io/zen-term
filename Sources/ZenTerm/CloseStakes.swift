import ControlProtocol

/// What closing a tab or workspace would end. `isRunning` is the reading the close confirmations use.
struct CloseStakes: Equatable {
    let closesWindow: Bool
    let isRunning: Bool
    let panes: [ListResult.Pane]
    let floats: [String]

    var needsForce: Bool { closesWindow || isRunning }
}
