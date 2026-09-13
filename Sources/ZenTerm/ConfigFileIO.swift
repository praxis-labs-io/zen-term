import Foundation

enum ConfigFileIO {
    /// Returns "" for a missing file and throws for an unreadable one, so a rewrite never erases the config.
    static func readExistingOrEmpty(_ url: URL) throws -> String {
        guard FileManager.default.fileExists(atPath: url.path) else { return "" }
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Writes atomically to a symlink's target, so a dotfiles symlink stays a symlink.
    static func writePreservingSymlink(_ contents: String, to url: URL) throws {
        try contents.write(to: url.resolvingSymlinksInPath(), atomically: true, encoding: .utf8)
    }
}
