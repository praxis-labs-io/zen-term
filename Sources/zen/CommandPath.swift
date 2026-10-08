import ArgumentParser
import ControlProtocol
import Foundation

/// Turns the paths a person types into the absolute ones the app takes, since it cannot see this shell's folder.
enum CommandPath {
    static func workspace(_ text: String) -> String { workspace(text, in: FileManager.default.currentDirectoryPath) }

    static func workspace(_ text: String, in cwd: String) -> String {
        guard looksLikePath(text) else { return text }
        return absolute(text, in: cwd)
    }

    // A worktree's title and a branch can hold a slash, so only these prefixes read as a folder.
    static func looksLikePath(_ text: String) -> Bool {
        text.hasPrefix("/") || text.hasPrefix("~") || text.hasPrefix(".")
    }

    static func folder(_ text: String) throws -> String {
        try folder(text, in: FileManager.default.currentDirectoryPath)
    }

    static func folder(_ text: String, in cwd: String) throws -> String {
        let path = absolute(text, in: cwd)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ValidationError("There is no folder at \(path).")
        }
        return path
    }

    static func absolute(_ text: String, in cwd: String) -> String {
        let expanded = (text as NSString).expandingTildeInPath
        let url =
            expanded.hasPrefix("/")
            ? URL(fileURLWithPath: expanded) : URL(fileURLWithPath: cwd).appendingPathComponent(expanded)
        return url.standardizedFileURL.path
    }
}
