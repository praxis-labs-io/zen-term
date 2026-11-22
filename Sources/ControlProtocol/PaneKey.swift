/// A key `pane.keys` presses, by the name it goes by on the wire, like `enter`, `up` or `ctrl-c`.
public enum PaneKey: Equatable, Sendable {
    case enter, escape, tab, shiftTab, backspace, space
    case up, down, left, right
    case home, end, pageUp, pageDown
    /// Control with a letter, a to z.
    case control(Character)

    private static let named: [(String, PaneKey)] = [
        ("enter", .enter), ("escape", .escape), ("tab", .tab), ("shift-tab", .shiftTab),
        ("backspace", .backspace), ("space", .space), ("up", .up), ("down", .down), ("left", .left),
        ("right", .right), ("home", .home), ("end", .end), ("pageup", .pageUp), ("pagedown", .pageDown),
    ]

    private static let controlPrefix = "ctrl-"

    /// Nil for a name that is not a key. Matches case-sensitively.
    public init?(name: String) {
        if let found = Self.named.first(where: { $0.0 == name }) {
            self = found.1
            return
        }
        guard name.hasPrefix(Self.controlPrefix) else { return nil }
        let letter = name.dropFirst(Self.controlPrefix.count)
        guard letter.count == 1, let character = letter.first, ("a"..."z").contains(character) else { return nil }
        self = .control(character)
    }

    public var name: String {
        if case .control(let letter) = self { return Self.controlPrefix + String(letter) }
        return Self.named.first { $0.1 == self }?.0 ?? ""
    }

    /// Every name, with the control keys written once as `ctrl-<letter>`.
    public static let names: [String] = named.map(\.0) + [controlPrefix + "<letter>"]
}
