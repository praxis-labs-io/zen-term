/// The `cmd` of a request.
public enum ControlCommand: String, Codable, Sendable, CaseIterable {
    case hello
    case list
}
