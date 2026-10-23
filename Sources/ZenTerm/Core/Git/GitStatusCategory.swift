import TerminalKit

enum GitStatusCategory: CaseIterable {
    case staged
    case modified
    case untracked
    case renamed
    case deleted
    case conflicted

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

    static func tokens(counting count: (GitStatusCategory) -> Int) -> [(category: GitStatusCategory, text: String)] {
        allCases.compactMap { category in
            let found = count(category)
            return found > 0 ? (category, "\(category.glyph)\(found)") : nil
        }
    }

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
