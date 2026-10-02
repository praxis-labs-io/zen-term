/// The text forms of window, tab and workspace addresses. Ids are minted per window, so a tab address carries both.
public enum ControlAddress {
    public static let hostPrefix = "ssh:"

    public static func window(_ window: Int) -> String { "w\(window)" }

    public static func tab(window: Int, tab: Int) -> String { "w\(window).t\(tab)" }

    /// Reads `w<window>.t<tab>`, or nil for anything else.
    public static func tab(_ address: String) -> (window: Int, tab: Int)? {
        let parts = address.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].first == "w", parts[1].first == "t",
            let window = Int(parts[0].dropFirst()), let tab = Int(parts[1].dropFirst())
        else { return nil }
        return (window, tab)
    }

    /// What a workspace address names: an absolute folder path, an SSH host, or otherwise a title.
    public enum Workspace: Equatable, Sendable {
        case folder(String)
        case host(String)
        case title(String)

        public init(_ address: String) {
            if address.hasPrefix("/") {
                self = .folder(address)
            } else if address.hasPrefix(ControlAddress.hostPrefix) {
                self = .host(String(address.dropFirst(ControlAddress.hostPrefix.count)))
            } else {
                self = .title(address)
            }
        }
    }
}
