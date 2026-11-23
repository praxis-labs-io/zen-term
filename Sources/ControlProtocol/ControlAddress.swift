/// The text forms of window, tab, workspace and pane addresses. Ids are minted per window, so a tab address carries both.
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

    /// A pane by its token, or by the name `pane.run` gave it. A string of digits is a token.
    public enum Pane: Codable, Equatable, Hashable, Sendable, ExpressibleByIntegerLiteral {
        case token(Int)
        case name(String)

        public init(_ text: String) {
            if !text.isEmpty, text.allSatisfy({ $0.isASCII && $0.isNumber }), let token = Int(text) {
                self = .token(token)
            } else {
                self = .name(text)
            }
        }

        public init(integerLiteral token: Int) { self = .token(token) }

        public init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let token = try? c.decode(Int.self) {
                self = .token(token)
            } else {
                self = Pane(try c.decode(String.self))
            }
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .token(let token): try c.encode(token)
            case .name(let name): try c.encode(name)
            }
        }

        /// Whether `name` can name a pane: not empty, and not something that reads as a token.
        public static func isValidName(_ name: String) -> Bool {
            !name.allSatisfy(\.isWhitespace) && Pane(name) == .name(name)
        }
    }
}
