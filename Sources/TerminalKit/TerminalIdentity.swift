import GhosttyKit

/// The variables naming this terminal and its color depth, as its own child processes see them.
public enum TerminalIdentity {
    public static let environment: [String: String] = [
        "COLORTERM": "truecolor",
        "TERM_PROGRAM": "ghostty",
        "TERM_PROGRAM_VERSION": version,
    ]

    private static var version: String {
        let info = ghostty_info()
        guard let bytes = info.version else { return "" }
        return String(
            decoding: UnsafeRawBufferPointer(start: bytes, count: Int(info.version_len)), as: UTF8.self)
    }
}
