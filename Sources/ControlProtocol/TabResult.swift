/// The tab a command opened, and the token of its first pane.
public struct TabResult: ControlPayload, Equatable {
    public let tab: String
    public let pane: Int

    public init(tab: String, pane: Int) {
        self.tab = tab
        self.pane = pane
    }
}
