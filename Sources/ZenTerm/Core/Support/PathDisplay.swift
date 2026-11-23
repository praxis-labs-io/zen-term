import Foundation

enum PathDisplay {
    static let homePath = FileManager.default.homeDirectoryForCurrentUser.path
    static let homeName = FileManager.default.homeDirectoryForCurrentUser.lastPathComponent

    // A tab or workspace never reads as a bare `~`, nor as `/`.
    static func folderName(_ url: URL) -> String? {
        if url.standardizedFileURL.path == homePath { return homeName }
        let name = url.lastPathComponent
        return name.isEmpty || name == "/" ? nil : name
    }

    static func folderName(fromTitle title: String) -> String { title == "~" ? homeName : title }

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
