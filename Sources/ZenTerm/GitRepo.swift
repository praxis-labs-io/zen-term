import Foundation

enum GitRepo {
    static func isGitRepo(_ dir: URL) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent(".git").path)
    }

    static func currentBranch(_ dir: URL) -> String? {
        guard let head = headFile(for: dir),
            let text = try? String(contentsOf: head, encoding: .utf8)
        else { return nil }
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.hasPrefix("ref: ") else {
            return line.isEmpty ? nil : String(line.prefix(7))
        }
        let ref = String(line.dropFirst("ref: ".count))
        guard ref.hasPrefix("refs/heads/") else { return ref.isEmpty ? nil : ref }
        return String(ref.dropFirst("refs/heads/".count))
    }

    private static func headFile(for dir: URL) -> URL? {
        let dotGit = dir.appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) else {
            return nil
        }
        if isDirectory.boolValue { return dotGit.appendingPathComponent("HEAD") }
        guard let pointer = try? String(contentsOf: dotGit, encoding: .utf8),
            let path = pointer.split(whereSeparator: \.isNewline)
                .first(where: { $0.hasPrefix("gitdir:") })
                .map({ $0.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces) }),
            !path.isEmpty
        else { return nil }
        let gitDir =
            path.hasPrefix("/")
            ? URL(fileURLWithPath: path)
            : dir.appendingPathComponent(path).standardizedFileURL
        return gitDir.appendingPathComponent("HEAD")
    }

    /// Stops when the path stops shrinking: `deletingLastPathComponent()` on a FileManager URL walks past "/" into "/..".
    static func repoRoot(for cwd: URL?) -> URL? {
        guard var dir = cwd?.standardizedFileURL else { return nil }
        while true {
            if isGitRepo(dir) { return dir }
            let parent = dir.deletingLastPathComponent()
            guard parent.path.count < dir.path.count else { return nil }
            dir = parent
        }
    }
}
