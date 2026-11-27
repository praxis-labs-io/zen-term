import Foundation

/// Why an `AgentInstaller` changed nothing, or stopped partway; `message` is written for the person who ran it.
public struct SetupError: Error, Equatable, Sendable {
    public let message: String

    public init(message: String) {
        self.message = message
    }

    static func malformed(_ url: URL, _ problem: String) -> SetupError {
        SetupError(message: "\(url.path) \(problem), so setup left it as it is. Fix it, then run setup again.")
    }

    static func unwritable(_ url: URL, _ error: Error) -> SetupError {
        SetupError(message: "Couldn't write \(url.path): \(error.localizedDescription)")
    }

    static func unreadable(_ url: URL, _ error: Error) -> SetupError {
        SetupError(message: "Couldn't read \(url.path): \(error.localizedDescription)")
    }
}
