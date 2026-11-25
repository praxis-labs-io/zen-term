import Foundation

// The line a failed ssh login left on its terminal that says why, when it left one a person can act on.
enum SSHFailureReason {
    // ProxyJump's nested ssh reports its own end after the real reason.
    private static let jumpHostClosed = "Connection closed by UNKNOWN port 65535"
    private static let closedByPeer = #/^Connection closed by \S+ port \d+$/#
    private static let sshPrefix = "ssh: "

    static func parse(_ tail: String) -> String? {
        var lines = tail.split(whereSeparator: \.isNewline)
            .map { $0.replacingOccurrences(of: "\r", with: "").trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix(SSHConnection.loginBanner) }
        if lines.last == jumpHostClosed { lines.removeLast() }
        guard let last = lines.last, last.wholeMatch(of: closedByPeer) == nil else { return nil }
        guard last.hasPrefix(sshPrefix) else { return last }
        let reason = last.dropFirst(sshPrefix.count)
        return reason.prefix(1).uppercased() + reason.dropFirst()
    }
}
