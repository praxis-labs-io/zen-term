/// Why `pane.wait` answered, with `pane` as `pane.get` reports it or the caller's `children`. On `exited`, when known:
/// `exitCode`, the last lines as `text`, and `outputFile`, the path of a `pane.run` pane's saved output.
/// `timeoutCapped` is the seconds waited when the asked timeout was longer.
public struct WaitResult: ControlPayload, Equatable {
    public let reason: WaitReason
    public let exitCode: Int?
    public let text: String?
    public let outputFile: String?
    public let pane: ListResult.Pane?
    public let children: [Child]?
    public private(set) var timeoutCapped: Int?

    public init(
        reason: WaitReason, exitCode: Int? = nil, text: String? = nil, outputFile: String? = nil, pane: ListResult.Pane
    ) {
        self.reason = reason
        self.exitCode = exitCode
        self.text = text
        self.outputFile = outputFile
        self.pane = pane
        children = nil
    }

    public init(reason: WaitReason, children: [Child]) {
        self.reason = reason
        exitCode = nil
        text = nil
        outputFile = nil
        pane = nil
        self.children = children
    }

    public func capped(at seconds: Int) -> WaitResult {
        var capped = self
        capped.timeoutCapped = seconds
        return capped
    }

    /// One child the wait watched. `reason` is its own news during the wait, absent when it had none.
    public struct Child: Codable, Equatable, Sendable {
        public let reason: WaitReason?
        public let exitCode: Int?
        public let text: String?
        public let outputFile: String?
        public let pane: ListResult.Pane

        public init(
            reason: WaitReason? = nil, exitCode: Int? = nil, text: String? = nil, outputFile: String? = nil,
            pane: ListResult.Pane
        ) {
            self.reason = reason
            self.exitCode = exitCode
            self.text = text
            self.outputFile = outputFile
            self.pane = pane
        }
    }
}

public enum WaitReason: String, Codable, Sendable {
    case stopped, exited, output, message, timeout
    case noChildren = "no_children"
}
