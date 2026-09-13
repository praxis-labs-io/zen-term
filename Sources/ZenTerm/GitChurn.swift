import Foundation

/// What a repo has in flight: how far its branch has drifted from the remote, and what its working
/// tree is holding. Parsed from one `git status --porcelain=v2 --branch`, in the vocabulary a
/// starship prompt already uses, so a row reads the way the shell below it does.
struct GitChurn: Equatable {
    var ahead = 0
    var behind = 0
    var staged = 0
    var modified = 0
    var untracked = 0
    var renamed = 0
    var deleted = 0
    var conflicted = 0

    var isEmpty: Bool { self == GitChurn() }

    /// Parse `git status --porcelain=v2 --branch` output. Format v2 rather than v1: it reports
    /// ahead/behind on a `# branch.ab` header, so the remote drift and the working tree come back
    /// from one call instead of two.
    static func parse(_ output: String) -> GitChurn {
        var churn = GitChurn()
        for line in output.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("# branch.ab ") {
                for field in line.dropFirst("# branch.ab ".count).split(separator: " ") {
                    let count = Int(field.dropFirst()) ?? 0
                    if field.hasPrefix("+") { churn.ahead = count }
                    if field.hasPrefix("-") { churn.behind = count }
                }
            } else if line.hasPrefix("? ") {
                churn.add(.untracked)
            } else if line.hasPrefix("u ") {
                churn.add(.conflicted)
            } else if line.hasPrefix("1 ") || line.hasPrefix("2 ") {
                churn.count(entry: line)
            }
        }
        return churn
    }

    func count(of category: GitStatusCategory) -> Int {
        switch category {
        case .staged: return staged
        case .modified: return modified
        case .untracked: return untracked
        case .renamed: return renamed
        case .deleted: return deleted
        case .conflicted: return conflicted
        }
    }

    private mutating func add(_ category: GitStatusCategory) {
        switch category {
        case .staged: staged += 1
        case .modified: modified += 1
        case .untracked: untracked += 1
        case .renamed: renamed += 1
        case .deleted: deleted += 1
        case .conflicted: conflicted += 1
        }
    }

    private mutating func count(entry line: Substring) {
        let fields = line.split(separator: " ")
        guard fields.count >= 2, fields[1].count == 2 else { return }
        let code = Array(fields[1])
        let categories = GitStatusCategory.categories(
            index: code[0], worktree: code[1], isRename: line.hasPrefix("2 "))
        categories.forEach { add($0) }
    }
}
