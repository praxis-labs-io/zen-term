/// The `error` of a response that is not `ok`. A `refused` error carries what `force` would end in `details`.
public struct ControlError: Error, Codable, Equatable, Sendable {
    public let code: ControlErrorCode
    public let message: String
    public let details: Details?

    public init(_ code: ControlErrorCode, _ message: String, details: Details? = nil) {
        self.code = code
        self.message = message
        self.details = details
    }

    /// The running panes and floats a close would stop, and whether it would close the window.
    public struct Details: Codable, Equatable, Sendable {
        public let panes: [ListResult.Pane]
        public let floats: [String]
        public let closesWindow: Bool

        public init(panes: [ListResult.Pane], floats: [String], closesWindow: Bool) {
            self.panes = panes
            self.floats = floats
            self.closesWindow = closesWindow
        }
    }
}
