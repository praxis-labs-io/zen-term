/// A failure that ends `zen` with its own exit code.
struct ZenFailure: Error, Equatable {
    static let appErrorCode: Int32 = 1
    static let usageCode: Int32 = 2
    static let noInstanceCode: Int32 = 3

    let exitCode: Int32
    let message: String

    static func app(_ message: String) -> ZenFailure { ZenFailure(exitCode: appErrorCode, message: message) }

    static func noInstance(_ message: String) -> ZenFailure {
        ZenFailure(exitCode: noInstanceCode, message: message)
    }
}
