import Foundation

/// Filesystem display + probing helpers shared across the chrome, so the home-tilde rule and the
/// directory check live in one place instead of drifting between hand-rolled copies.
enum PathDisplay {
    /// The current user's home directory path, resolved once (it can't change during the process).
    static let homePath = FileManager.default.homeDirectoryForCurrentUser.path

    /// Collapse a leading home prefix to `~`. Requires an exact match or the `home + "/"` boundary,
    /// so a sibling directory like `/Users/drucial2/proj` is left untouched instead of mangled to
    /// `~2/proj`. Non-home paths are returned unchanged.
    static func abbreviatingHome(_ path: String) -> String {
        if path == homePath { return "~" }
        return path.hasPrefix(homePath + "/") ? "~" + path.dropFirst(homePath.count) : path
    }

    /// Whether `url` points at an existing directory (not a regular file).
    static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }
}
