import Foundation

// Why a failed ssh login ended: ssh's own line from its terminal, and the plain headline the Connect screen gives it.
enum SSHFailureReason {
    // ProxyJump's nested ssh reports its own end after the real reason.
    private static let jumpHostClosed = "Connection closed by UNKNOWN port 65535"
    private static let closedByPeer = #/^Connection closed by \S+ port \d+$/#
    private static let sshPrefix = "ssh: "
    private static let unknownHeadline = "Couldn't connect"
    private static let headlines: [(mark: String, headline: String)] = [
        ("Could not resolve hostname", "This host can't be found"),
        ("Connection refused", "The host refused the connection"),
        ("Operation timed out", "The host didn't answer"),
        ("Connection timed out", "The host didn't answer"),
        ("Permission denied (", "Couldn't sign in"),
        ("Host key verification failed", "Couldn't verify the host's key"),
    ]

    static func parse(_ tail: String) -> String? {
        var lines = tail.split(whereSeparator: \.isNewline)
            .map { $0.replacingOccurrences(of: "\r", with: "").trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix(SSHConnection.loginBanner) }
        if lines.last == jumpHostClosed { lines.removeLast() }
        guard let last = lines.last, last.wholeMatch(of: closedByPeer) == nil else { return nil }
        return last.hasPrefix(sshPrefix) ? String(last.dropFirst(sshPrefix.count)) : last
    }

    static func headline(for reason: String?) -> String {
        guard let reason else { return unknownHeadline }
        return headlines.first { reason.contains($0.mark) }?.headline ?? unknownHeadline
    }
}
