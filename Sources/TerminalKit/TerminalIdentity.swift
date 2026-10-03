import GhosttyKit

/// The variables naming this terminal that its own child processes see, such as `TERM_PROGRAM`.
public enum TerminalIdentity {
    public static let environment: [String: String] = [
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
