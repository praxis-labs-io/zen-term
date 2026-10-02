/// The `error` of a response that is not `ok`.
public struct ControlError: Error, Codable, Equatable, Sendable {
    public let code: ControlErrorCode
    public let message: String

    public init(_ code: ControlErrorCode, _ message: String) {
        self.code = code
        self.message = message
    }
}
