import TerminalKit

enum GitStatusCategory: CaseIterable {
    case staged
    case modified
    case untracked
    case renamed
    case deleted
    case conflicted

    /// Each half of `XY` counts on its own, so a staged edit later deleted is both staged and deleted.
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

    /// Each category `count` finds any of, with its glyph and count, in the order a starship prompt writes them.
    static func tokens(counting count: (GitStatusCategory) -> Int) -> [(category: GitStatusCategory, text: String)] {
        allCases.compactMap { category in
            let found = count(category)
            return found > 0 ? (category, "\(category.glyph)\(found)") : nil
        }
    }

    /// Nerd-font glyphs render as a box in the system font the chrome draws in.
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
