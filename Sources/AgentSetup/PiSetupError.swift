import Foundation

/// Why `PiSetup` changed nothing, or stopped partway.
public struct PiSetupError: Error, Equatable, Sendable {
    public let message: String

    public init(message: String) { self.message = message }

    static func unreadable(_ url: URL, _ error: Error) -> PiSetupError {
        PiSetupError(message: "Couldn't read \(url.path): \(error.localizedDescription)")
    }

    static func unwritable(_ url: URL, _ error: Error) -> PiSetupError {
        PiSetupError(message: "Couldn't write \(url.path): \(error.localizedDescription)")
    }
}
