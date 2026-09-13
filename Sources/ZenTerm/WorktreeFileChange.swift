import Foundation

struct WorktreeFileChange: Equatable {
    let path: String
    let categories: [GitStatusCategory]

    static func parse(_ output: String) -> [WorktreeFileChange] {
        let fields = output.split(separator: "\0")
        var changes: [WorktreeFileChange] = []
        var index = fields.startIndex
        while index < fields.endIndex {
            let record = fields[index]
            index += 1
            switch record.first {
            case "1": changes += change(in: record, fixedFields: 8)
            case "2":
                changes += change(in: record, fixedFields: 9)
                index += 1
            case "u": changes += conflict(in: record)
            case "?": changes.append(WorktreeFileChange(path: String(record.dropFirst(2)), categories: [.untracked]))
            default: continue
            }
        }
        return changes
    }

    private static func change(in record: Substring, fixedFields: Int) -> [WorktreeFileChange] {
        let fields = record.split(separator: " ", maxSplits: fixedFields)
        guard fields.count == fixedFields + 1, fields[1].count == 2 else { return [] }
        let code = Array(fields[1])
        let found = GitStatusCategory.categories(
            index: code[0], worktree: code[1], isRename: record.first == "2")
        let categories = GitStatusCategory.allCases.filter(found.contains)
        return [WorktreeFileChange(path: String(fields[fixedFields]), categories: categories)]
    }

    private static let conflictFixedFields = 10

    private static func conflict(in record: Substring) -> [WorktreeFileChange] {
        let fields = record.split(separator: " ", maxSplits: conflictFixedFields)
        guard fields.count == conflictFixedFields + 1 else { return [] }
        return [WorktreeFileChange(path: String(fields[conflictFixedFields]), categories: [.conflicted])]
    }
}
