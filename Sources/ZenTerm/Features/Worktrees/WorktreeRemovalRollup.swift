import Foundation

enum WorktreeRemovalRollup {
    static let rowLimit = 8

    enum Row: Equatable {
        case file(WorktreeFileChange)
        case folder(path: String, files: [WorktreeFileChange])
        case more(hiddenFiles: Int)
    }

    static func rows(for files: [WorktreeFileChange]) -> [Row] {
        let sorted = files.sorted { $0.path < $1.path }
        let collapsed = foldersToCollapse(sorted)
        var rows: [Row] = []
        var index = sorted.startIndex
        while index < sorted.endIndex {
            guard let folder = ancestors(of: sorted[index].path).first(where: collapsed.contains) else {
                rows.append(.file(sorted[index]))
                index += 1
                continue
            }
            let end = sorted[index...].firstIndex { !$0.path.hasPrefix(folder + "/") } ?? sorted.endIndex
            rows.append(.folder(path: folder, files: Array(sorted[index..<end])))
            index = end
        }
        guard rows.count > rowLimit else { return rows }
        let hidden = rows[(rowLimit - 1)...].reduce(0) { $0 + changes(in: $1).count }
        return Array(rows.prefix(rowLimit - 1)) + [.more(hiddenFiles: hidden)]
    }

    private static func foldersToCollapse(_ sorted: [WorktreeFileChange]) -> Set<String> {
        var filesInside: [String: Int] = [:]
        for file in sorted {
            for folder in ancestors(of: file.path) { filesInside[folder, default: 0] += 1 }
        }
        let ranked = filesInside.keys.sorted { lhs, rhs in
            let lhsRank = (depth(lhs), filesInside[lhs, default: 0])
            let rhsRank = (depth(rhs), filesInside[rhs, default: 0])
            return lhsRank == rhsRank ? lhs < rhs : lhsRank > rhsRank
        }
        var rowsInside = filesInside
        var rowCount = sorted.count
        var collapsed: Set<String> = []
        for folder in ranked where rowCount > rowLimit {
            let inside = rowsInside[folder, default: 0]
            guard inside > 1 else { continue }
            collapsed.insert(folder)
            for ancestor in ancestors(of: folder) { rowsInside[ancestor, default: 0] -= inside - 1 }
            rowCount -= inside - 1
        }
        return collapsed
    }

    private static func changes(in row: Row) -> [WorktreeFileChange] {
        switch row {
        case .file(let file): return [file]
        case .folder(_, let files): return files
        case .more: return []
        }
    }

    private static func ancestors(of path: String) -> [String] {
        let parts = path.split(separator: "/").dropLast()
        return parts.indices.map { parts[...$0].joined(separator: "/") }
    }

    private static func depth(_ folder: String) -> Int {
        folder.split(separator: "/").count
    }
}
