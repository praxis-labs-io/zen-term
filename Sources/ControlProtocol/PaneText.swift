/// What `pane.read` read, with trailing blank lines dropped.
public struct PaneText: ControlPayload, Equatable {
    public let text: String
    /// With `since`, true when the start is no longer readable, so the text is read from the oldest row or the
    /// screen showing.
    public let truncated: Bool?

    public init(text: String, truncated: Bool? = nil) {
        self.text = text
        self.truncated = truncated
    }
}
