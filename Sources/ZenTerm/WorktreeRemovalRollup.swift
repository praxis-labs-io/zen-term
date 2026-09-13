import Foundation

enum WorktreeRemovalRollup {
    static let rowLimit = 8

    enum Row: Equatable {
        case file(WorktreeFileChange)
        case folder(path: String, files: [WorktreeFileChange])
        case more(hiddenFiles: Int)
    }

    /// Every file while they fit in `rowLimit` rows. Past that, the deepest folder holding more than
    /// one row collapses into one, then the next, and a final `.more` row counts what still spills.
    static func rows(for files: [WorktreeFileChange]) -> [Row] {
        var rows = files.sorted { $0.path < $1.path }.map(Row.file)
        while rows.count > rowLimit, let folder = deepestCrowdedFolder(in: rows) {
            let inside = rows.indices.filter { path(of: rows[$0]).hasPrefix(folder + "/") }
            guard let first = inside.first, let last = inside.last else { break }
            let collapsed = Row.folder(path: folder, files: inside.flatMap { changes(in: rows[$0]) })
            rows.replaceSubrange(first...last, with: [collapsed])
        }
        guard rows.count > rowLimit else { return rows }
        let hidden = rows[(rowLimit - 1)...].reduce(0) { $0 + changes(in: $1).count }
        return Array(rows.prefix(rowLimit - 1)) + [.more(hiddenFiles: hidden)]
    }

    private static func deepestCrowdedFolder(in rows: [Row]) -> String? {
        let folders = Set(rows.flatMap { ancestors(of: path(of: $0)) })
        let crowded = folders.compactMap { folder -> (folder: String, rows: Int, files: Int)? in
            let inside = rows.filter { path(of: $0).hasPrefix(folder + "/") }
            guard inside.count > 1 else { return nil }
            return (folder, inside.count, inside.flatMap(changes(in:)).count)
        }
        return crowded.max { lhs, rhs in
            let lhsRank = (depth(lhs.folder), lhs.files)
            let rhsRank = (depth(rhs.folder), rhs.files)
            return lhsRank == rhsRank ? lhs.folder > rhs.folder : lhsRank < rhsRank
        }?.folder
    }

    private static func path(of row: Row) -> String {
        switch row {
        case .file(let file): return file.path
        case .folder(let path, _): return path
        case .more: return ""
        }
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
