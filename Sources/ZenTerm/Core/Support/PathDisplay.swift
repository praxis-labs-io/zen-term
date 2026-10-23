import Foundation

enum PathDisplay {
    static let homePath = FileManager.default.homeDirectoryForCurrentUser.path

    static func abbreviatingHome(_ path: String) -> String {
        if path == homePath { return "~" }
        return path.hasPrefix(homePath + "/") ? "~" + path.dropFirst(homePath.count) : path
    }

    static func expandingHome(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }
}
