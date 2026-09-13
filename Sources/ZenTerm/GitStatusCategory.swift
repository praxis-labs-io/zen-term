import TerminalKit

enum GitStatusCategory: CaseIterable {
    case staged
    case modified
    case untracked
    case renamed
    case deleted
    case conflicted

    /// The categories one `1` or `2` record's `XY` code counts under: `index` is the index against
    /// HEAD and `worktree` the working tree against the index. A delete on both sides counts twice.
    static func categories(index: Character, worktree: Character, isRename: Bool) -> [GitStatusCategory] {
        var categories: [GitStatusCategory] = []
        if index == "D" {
            categories.append(.deleted)
        } else if isRename {
            categories.append(.renamed)
        } else if index != "." {
            categories.append(.staged)
        }
        if worktree == "D" {
            categories.append(.deleted)
        } else if worktree != "." {
            categories.append(.modified)
        }
        return categories
    }

    /// Nerd-font glyphs are out: the chrome draws in the system font, where a private-use codepoint
    /// renders as a box.
    var glyph: String {
        switch self {
        case .staged: return "+"
        case .modified: return "~"
        case .untracked: return "?"
        case .renamed: return "»"
        case .deleted: return "-"
        case .conflicted: return "≠"
        }
    }

    var role: KeyPath<ChromeTheme, TerminalColor> {
        switch self {
        case .staged: return \.positive
        case .modified: return \.warning
        case .untracked: return \.attention
        case .renamed: return \.info
        case .deleted: return \.destructive
        case .conflicted: return \.accent
        }
    }
}
