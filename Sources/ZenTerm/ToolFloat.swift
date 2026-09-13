import AppKit

struct ToolFloat: Equatable {
    /// Derived from the title, not the order: titles change only by rename, order changes routinely.
    let id: String
    var order: Int
    let title: String
    let icon: String
    let command: String
    let dir: URL?
    let widthFraction: CGFloat
    let heightFraction: CGFloat
    let requiresGitRepo: Bool

    enum Persistence: String {
        case ephemeral = "none"
        case directory = "dir"
        case window
    }

    /// Not `RawRepresentable` so tab scope stays unparseable from config; only Scratch wants it.
    enum Scope { case window, tab }

    let persist: Persistence
    let toggle: Chord
    var showsInToolbar: Bool = true
    var scope: Scope = .window
}

extension ToolFloat {
    /// Its `toggle` is only the default chord; render glyphs from `CommandCatalog.spec(for:)`.
    static let scratch = ToolFloat(
        id: "scratch",
        order: 0,
        title: "Scratch",
        icon: "square.fill.on.square",
        command: "",
        dir: nil,
        widthFraction: 0.7,
        heightFraction: 0.6,
        requiresGitRepo: false,
        persist: .window,
        toggle: Chord(command: true, key: ";"),
        showsInToolbar: true,
        scope: .tab)

    static let builtInIDs: Set<String> = [scratch.id]

    static func isBuiltIn(_ id: String) -> Bool { builtInIDs.contains(id) }
}

enum ToolFloatCatalog {
    static let builtIns: [ToolFloat] = [.scratch]

    static var userDefined: [ToolFloat] { GeneralConfig.current.floats }

    static var all: [ToolFloat] { builtIns + userDefined }

    static func byID(_ id: String) -> ToolFloat? { all.first { $0.id == id } }
}
