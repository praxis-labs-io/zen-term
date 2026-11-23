/// Who sent a request: `pane` is the client's `$ZEN_PANE` when it runs in one, and `cwd` the client's own folder.
public struct ControlCaller: Codable, Equatable, Sendable {
    public let pane: Int?
    public let cwd: String?

    public init(pane: Int?) { self.init(pane: pane, cwd: nil) }

    public init(pane: Int?, cwd: String?) {
        self.pane = pane
        self.cwd = cwd
    }
}
