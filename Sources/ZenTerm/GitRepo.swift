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

    #if DEBUG
        static var homeOverrideForTesting: URL?
    #endif

    private static var home: URL {
        #if DEBUG
            if let homeOverrideForTesting { return homeOverrideForTesting }
        #endif
        return FileManager.default.homeDirectoryForCurrentUser
    }

    /// Stops when the path stops shrinking: `deletingLastPathComponent()` on a FileManager URL walks past "/" into "/..".
    /// Home is never an enclosing repo, or dotfiles tracked at `~` would claim every folder under it.
    static func repoRoot(for cwd: URL?) -> URL? {
        guard var dir = cwd?.standardizedFileURL else { return nil }
        let ceiling = home.standardizedFileURL.path
        while true {
            if isGitRepo(dir) { return dir }
            let parent = dir.deletingLastPathComponent()
            guard parent.path.count < dir.path.count, parent.path != ceiling else { return nil }
            dir = parent
        }
    }

    /// Where `path` sits inside `checkout`: the same spot under `repoRoot`, or `checkout` for the root itself.
    /// Nil when `path` is below `repoRoot` and that folder is not in `checkout`.
    static func mirrored(_ path: URL, from repoRoot: URL?, into checkout: URL) -> URL? {
        let checkout = checkout.standardizedFileURL
        guard let base = repoRoot?.standardizedFileURL.path else { return checkout }
        let inside = path.standardizedFileURL.path
        guard inside.hasPrefix(base + "/") else { return checkout }
        let mirrored = checkout.appendingPathComponent(String(inside.dropFirst(base.count + 1)))
            .standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: mirrored.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else { return nil }
        return mirrored
    }
}
