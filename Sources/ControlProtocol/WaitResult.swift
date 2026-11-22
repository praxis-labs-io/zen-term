/// Why `pane.wait` answered, with the waited-on pane as `pane.get` reports it.
/// `exitCode` is the shell's report and `text` the last lines of output, both only on `exited` and each when known.
public struct WaitResult: ControlPayload, Equatable {
    public let reason: WaitReason
    public let exitCode: Int?
    public let text: String?
    public let pane: ListResult.Pane

    public init(reason: WaitReason, exitCode: Int? = nil, text: String? = nil, pane: ListResult.Pane) {
        self.reason = reason
        self.exitCode = exitCode
        self.text = text
        self.pane = pane
    }
}

public enum WaitReason: String, Codable, Sendable {
    case stopped, exited, output, message, timeout
}
