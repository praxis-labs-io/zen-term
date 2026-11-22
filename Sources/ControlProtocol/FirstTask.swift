/// Whether `pane.run` sent its task, and why not when it did not.
public struct FirstTask: Codable, Equatable, Sendable {
    public let sent: Bool
    public let reason: Reason?

    public init(sent: Bool, reason: Reason? = nil) {
        self.sent = sent
        self.reason = reason
    }

    public static let delivered = FirstTask(sent: true)

    public static func held(_ reason: Reason) -> FirstTask { FirstTask(sent: false, reason: reason) }

    /// `notReady`: the program failed or exited before it was ready. `blocked`: it was waiting on the person.
    /// `noStatus`: it sent no status report in time.
    public enum Reason: String, Codable, Sendable {
        case notReady = "not_ready"
        case blocked
        case noStatus = "no_status"
    }
}
