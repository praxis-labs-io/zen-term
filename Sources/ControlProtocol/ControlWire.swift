import Foundation

/// The framing both ends share: one JSON object per `\n`-terminated UTF-8 line.
public enum ControlWire {
    /// The protocol version this build speaks, sent as `v` on every request and response.
    public static let version = 1

    /// The longest line either end accepts, newline excluded.
    public static let maxLineLength = 64 * 1024

    /// The longest, in seconds, the app takes to answer a command that does not set its own deadline.
    public static let longestReplyWait = 300

    /// The seconds `pane.wait` holds when the request gives no `timeout`.
    public static let defaultPaneWait = 180

    /// The most seconds a `pane.wait` may hold.
    public static let longestPaneWait = 600

    /// Seconds past a held command's own timeout before the app gives up on its answer.
    public static let answerMargin = 5

    /// The seconds the app takes at most to answer `cmd`: a `pane.wait` its timeout plus `answerMargin`.
    public static func answerWait(for cmd: ControlCommand, _ args: ControlArgs) -> Int {
        guard cmd == .paneWait else { return longestReplyWait }
        return min(max(args.timeout ?? defaultPaneWait, 1), longestPaneWait) + answerMargin
    }

    /// One encoded line with its trailing newline.
    public static func line(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(value)
        data.append(0x0A)
        return data
    }
}
