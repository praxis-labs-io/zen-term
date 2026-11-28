/// What holds the Mac awake: any hold at all (`on`), whether the display is held too, the person's hold in the app
/// (`user`), the caller's own pane hold (`pane`), and every pane hold (`panes`), oldest first.
public struct AwakeResult: ControlPayload, Equatable {
    public let on: Bool
    public let display: Bool
    public let user: Bool
    public let pane: Hold?
    public let panes: [Hold]

    public init(on: Bool, display: Bool, user: Bool, pane: Hold?, panes: [Hold]) {
        self.on = on
        self.display = display
        self.user = user
        self.pane = pane
        self.panes = panes
    }

    /// One pane's hold, with the whole seconds it has left when it was started with a duration.
    public struct Hold: Codable, Equatable, Sendable {
        public let token: Int
        public let name: String
        public let remaining: Int?

        public init(token: Int, name: String, remaining: Int?) {
            self.token = token
            self.name = name
            self.remaining = remaining
        }
    }
}
