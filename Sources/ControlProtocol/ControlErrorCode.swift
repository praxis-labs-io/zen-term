public enum ControlErrorCode: String, Codable, Sendable, CaseIterable {
    case badRequest = "bad_request"
    case unknownCommand = "unknown_command"
    case unsupportedVersion = "unsupported_version"
    case notFound = "not_found"
    case ambiguous
    case refused
    case failed
}
