import Foundation

/// How a file changed between the two sides of a diff.
enum ChangeKind: Equatable {
    case added, deleted, modified, renamed, binary
}

/// The role a single line plays inside a hunk.
enum DiffLineKind: Equatable {
    case context, added, removed
}

/// One line of a hunk, carrying the line numbers it occupies on each side. A removed line
/// has no `newLineNumber`; an added line has no `oldLineNumber`; context has both.
struct DiffLine: Equatable {
    let kind: DiffLineKind
    let oldLineNumber: Int?
    let newLineNumber: Int?
    let text: String
}

/// A contiguous run of changed and surrounding lines, headed by an `@@ … @@` line.
struct Hunk: Equatable {
    let header: String
    let oldStart: Int
    let newStart: Int
    let lines: [DiffLine]
}

/// One changed file. `oldPath` is set only when the path moved (rename). Add/remove counts
/// are derived from the hunks so they can never drift from the lines actually rendered.
struct FileDiff: Equatable {
    let path: String
    let oldPath: String?
    let changeKind: ChangeKind
    let hunks: [Hunk]

    var addedCount: Int {
        hunks.reduce(0) { $0 + $1.lines.lazy.filter { $0.kind == .added }.count }
    }
    var removedCount: Int {
        hunks.reduce(0) { $0 + $1.lines.lazy.filter { $0.kind == .removed }.count }
    }
}

/// Parses `git diff` unified output into `[FileDiff]`. Pure and renderer-agnostic: the same
/// model feeds the side-by-side and unified renderers.
enum DiffParser {
    static func parse(_ unifiedDiff: String) -> [FileDiff] {
        var files: [FileDiff] = []

        // Per-file signals, reset by `flushFile`. The path is resolved from several sources
        // because binary files and pure renames carry no `---`/`+++` lines.
        var gitOld: String?
        var gitNew: String?
        var minusPath: String?
        var plusPath: String?
        var oldIsDevNull = false
        var newIsDevNull = false
        var renameFrom: String?
        var renameTo: String?
        var isRename = false
        var isBinary = false
        var started = false  // a `diff --git` was seen, so an empty-hunk file (binary/rename) still emits
        var hunks: [Hunk] = []

        var hunkHeader: String?
        var hunkOldStart = 0
        var hunkNewStart = 0
        var hunkLines: [DiffLine] = []
        var oldLine = 0
        var newLine = 0

        func flushHunk() {
            guard let header = hunkHeader else { return }
            hunks.append(Hunk(header: header, oldStart: hunkOldStart, newStart: hunkNewStart, lines: hunkLines))
            hunkHeader = nil
            hunkLines = []
        }

        func flushFile() {
            flushHunk()
            defer {
                gitOld = nil
                gitNew = nil
                minusPath = nil
                plusPath = nil
                oldIsDevNull = false
                newIsDevNull = false
                renameFrom = nil
                renameTo = nil
                isRename = false
                isBinary = false
                started = false
                hunks = []
            }
            guard started, let path = plusPath ?? renameTo ?? minusPath ?? gitNew ?? gitOld else { return }
            let kind: ChangeKind
            if isBinary {
                kind = .binary
            } else if isRename {
                kind = .renamed
            } else if oldIsDevNull {
                kind = .added
            } else if newIsDevNull {
                kind = .deleted
            } else {
                kind = .modified
            }
            files.append(
                FileDiff(
                    path: path,
                    oldPath: isRename ? (renameFrom ?? gitOld ?? minusPath) : nil,
                    changeKind: kind,
                    hunks: hunks))
        }

        for rawLine in unifiedDiff.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)

            if line.hasPrefix("diff --git ") {
                flushFile()
                started = true
                let paths = gitHeaderPaths(line)
                gitOld = paths.old
                gitNew = paths.new
                continue
            }
            if line.hasPrefix("rename from ") {
                renameFrom = String(line.dropFirst("rename from ".count))
                isRename = true
                continue
            }
            if line.hasPrefix("rename to ") {
                renameTo = String(line.dropFirst("rename to ".count))
                isRename = true
                continue
            }
            if line.hasPrefix("Binary files ") || line.hasPrefix("GIT binary patch") {
                isBinary = true
                continue
            }
            if line.hasPrefix("--- ") {
                let path = strippedPath(from: line, prefix: "--- ")
                minusPath = path
                oldIsDevNull = path == nil
                continue
            }
            if line.hasPrefix("+++ ") {
                let path = strippedPath(from: line, prefix: "+++ ")
                plusPath = path
                newIsDevNull = path == nil
                continue
            }
            if line.hasPrefix("@@") {
                flushHunk()
                guard let starts = parseHunkStarts(line) else { continue }
                hunkHeader = line
                hunkOldStart = starts.old
                hunkNewStart = starts.new
                oldLine = starts.old
                newLine = starts.new
                continue
            }

            guard hunkHeader != nil else { continue }  // index/mode/etc. lines between files

            if line.hasPrefix("\\") { continue }  // "\ No newline at end of file"

            if line.hasPrefix("+") {
                hunkLines.append(
                    DiffLine(kind: .added, oldLineNumber: nil, newLineNumber: newLine, text: String(line.dropFirst())))
                newLine += 1
            } else if line.hasPrefix("-") {
                hunkLines.append(
                    DiffLine(kind: .removed, oldLineNumber: oldLine, newLineNumber: nil, text: String(line.dropFirst()))
                )
                oldLine += 1
            } else if line.hasPrefix(" ") {
                hunkLines.append(
                    DiffLine(
                        kind: .context, oldLineNumber: oldLine, newLineNumber: newLine, text: String(line.dropFirst())))
                oldLine += 1
                newLine += 1
            }
        }
        flushFile()
        return files
    }

    /// Fallback paths from the `diff --git a/old b/new` header, used when a file carries no
    /// `---`/`+++` lines (binary files, pure renames). Splits on the ` b/` that separates the
    /// two sides; good enough for the unquoted paths git emits by default.
    private static func gitHeaderPaths(_ line: String) -> (old: String?, new: String?) {
        let body = String(line.dropFirst("diff --git ".count))
        guard let sep = body.range(of: " b/") else { return (nil, nil) }
        let old = String(body[body.startIndex..<sep.lowerBound])
        let new = String(body[sep.lowerBound...].dropFirst())
        return (stripSourcePrefix(old), stripSourcePrefix(new))
    }

    /// Drops a leading `a/` or `b/` diff-source prefix.
    private static func stripSourcePrefix(_ path: String) -> String {
        (path.hasPrefix("a/") || path.hasPrefix("b/")) ? String(path.dropFirst(2)) : path
    }

    /// The path from a `--- a/foo` / `+++ b/foo` header, with the `a/`/`b/` prefix removed,
    /// or nil for `/dev/null` (a created or deleted side).
    private static func strippedPath(from line: String, prefix: String) -> String? {
        let path = String(line.dropFirst(prefix.count))
        if path == "/dev/null" { return nil }
        return stripSourcePrefix(path)
    }

    /// The old/new start lines from an `@@ -old,n +new,m @@ …` header.
    private static func parseHunkStarts(_ line: String) -> (old: Int, new: Int)? {
        let segments = line.components(separatedBy: "@@")
        guard segments.count >= 2 else { return nil }
        let ranges = segments[1].split(separator: " ")
        guard ranges.count >= 2, ranges[0].hasPrefix("-"), ranges[1].hasPrefix("+") else { return nil }
        let old = Int(ranges[0].dropFirst().split(separator: ",")[0])
        let new = Int(ranges[1].dropFirst().split(separator: ",")[0])
        guard let old, let new else { return nil }
        return (old, new)
    }
}
