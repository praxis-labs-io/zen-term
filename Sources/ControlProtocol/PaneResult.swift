/// The token of the pane a command opened.
public struct PaneResult: ControlPayload, Equatable {
    public let pane: Int

    public init(pane: Int) { self.pane = pane }
}
