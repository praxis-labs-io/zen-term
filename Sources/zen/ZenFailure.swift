/// A failure that ends `zen` with its own exit code.
struct ZenFailure: Error, Equatable {
    static let appErrorCode: Int32 = 1
    static let usageCode: Int32 = 2
    static let noInstanceCode: Int32 = 3
    static let programFailedCode: Int32 = 4
    static let timeoutCode: Int32 = 5
    static let messageCode: Int32 = 6

    let exitCode: Int32
    let message: String

    static func app(_ message: String) -> ZenFailure { ZenFailure(exitCode: appErrorCode, message: message) }

    // A wait already printed its answer, so its exit code is all there is left to say.
    static func answered(_ exitCode: Int32) -> ZenFailure { ZenFailure(exitCode: exitCode, message: "") }

    static func noInstance(_ message: String) -> ZenFailure {
        ZenFailure(exitCode: noInstanceCode, message: message)
    }
}
