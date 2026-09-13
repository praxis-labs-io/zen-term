import Foundation

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

    /// Porcelain v2 because its `# branch.ab` header carries ahead/behind, so one call covers remote and worktree.
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
                churn.untracked += 1
            } else if line.hasPrefix("u ") {
                churn.conflicted += 1
            } else if line.hasPrefix("1 ") || line.hasPrefix("2 ") {
                churn.count(entry: line)
            }
        }
        return churn
    }

    /// Reads `X` and `Y` separately: `MD` is a staged edit then deleted, and one `D` for both would hide the staged work.
    private mutating func count(entry line: Substring) {
        let fields = line.split(separator: " ")
        guard fields.count >= 2, fields[1].count == 2 else { return }
        let staging = Array(fields[1])

        if staging[0] == "D" {
            deleted += 1
        } else if line.hasPrefix("2 ") {
            renamed += 1
        } else if staging[0] != "." {
            staged += 1
        }

        if staging[1] == "D" {
            deleted += 1
        } else if staging[1] != "." {
            modified += 1
        }
    }
}
