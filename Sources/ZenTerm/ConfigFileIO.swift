import Foundation

/// Shared file I/O for the config writers. Both `ConfigWriter` and `WorkspacesWriter` do a
/// whole-file read-modify-rewrite, and both depend on two load-bearing guards that are easy to
/// forget when copying: never treat an unreadable existing file as empty, and never clobber a
/// symlink. Centralizing them means the next config writer inherits both.
enum ConfigFileIO {
    /// The file's contents, or `""` if it doesn't exist. Propagates a read error for a file that
    /// *does* exist — never treat an unreadable file as empty, or the whole-file rewrite that
    /// follows would erase the user's config.
    static func readExistingOrEmpty(_ url: URL) throws -> String {
        guard FileManager.default.fileExists(atPath: url.path) else { return "" }
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Write `contents` atomically to the symlink's *target*, not over the symlink — a config
    /// symlinked into a dotfiles repo must keep pointing there (an atomic write would otherwise
    /// replace the symlink with a plain file).
    static func writePreservingSymlink(_ contents: String, to url: URL) throws {
        try contents.write(to: url.resolvingSymlinksInPath(), atomically: true, encoding: .utf8)
    }
}
