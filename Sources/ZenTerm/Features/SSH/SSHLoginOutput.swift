import Foundation

// What the Connect screen shows of ssh's own terminal lines during a login.
enum SSHLoginOutput {
    static let denied = "Permission denied, please try again."
    private static let addedHostKey = "Warning: Permanently added"

    static func detail(of lines: [String]) -> String? {
        lines.last { !$0.hasPrefix(addedHostKey) && $0 != denied }
    }

    static func saysDenied(_ lines: [String]) -> Bool { lines.contains(denied) }
}
