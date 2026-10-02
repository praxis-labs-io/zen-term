/// Who sent a request: `pane` is the client's `$ZEN_PANE` when it runs in one.
public struct ControlCaller: Codable, Equatable, Sendable {
    public let pane: Int?

    public init(pane: Int?) { self.pane = pane }
}
