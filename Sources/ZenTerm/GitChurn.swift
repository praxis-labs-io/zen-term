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
                churn.untracked += 1
            } else if line.hasPrefix("u ") {
                churn.conflicted += 1
            } else if line.hasPrefix("1 ") || line.hasPrefix("2 ") {
                churn.count(entry: line)
            }
        }
        return churn
    }

    /// One changed-entry line. Its second field is `XY`: `X` is the index against HEAD and `Y` the
    /// working tree against the index, so a file edited and then staged counts once on each side,
    /// which is what makes "staged" and "modified" separate numbers rather than one total.
    ///
    /// Each half is read on its own. Letting a `D` anywhere in `XY` speak for the whole entry loses
    /// the other side: `MD` is a staged edit the worktree then deleted, and reporting only the
    /// delete hides staged work a commit would still capture.
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
