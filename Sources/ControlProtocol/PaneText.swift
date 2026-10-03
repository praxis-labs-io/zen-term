/// What `pane.read` read, with trailing blank lines dropped.
public struct PaneText: ControlPayload, Equatable {
    public let text: String

    public init(text: String) { self.text = text }
}
