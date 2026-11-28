import AppLog
import Foundation
import TerminalKit

// A launched pane's last output, saved as its program exits because the pane closes with it.
enum RunOutput {
    static let savedRows = 2000
    static let cutNotice = "Earlier output was not saved. This file holds the last 2,000 screen lines."
    static var folderOverrideForTesting: URL?
    private static let queue = DispatchQueue(label: "zenterm.run-output", qos: .utility)

    private struct Tail {
        let text: String
        let isCut: Bool
        let startsMidLine: Bool
    }

    static var folder: URL {
        folderOverrideForTesting
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ZenTerm/run-output", isDirectory: true)
    }

    // Main reads one bounded span of the grid, where it lives; the rest runs off it, and `done` lands back on main.
    static func save(_ surface: TerminalSurface, token: Int, then done: @escaping (URL?) -> Void) {
        guard let tail = tail(of: surface) else { return done(nil) }
        let folder = folder
        let file = folder.appendingPathComponent("\(Int(Date().timeIntervalSince1970 * 1000))-\(token).txt")
        queue.async {
            let saved = write(contents(of: tail), to: file, in: folder)
            DispatchQueue.main.async { done(saved ? file : nil) }
        }
    }

    private static func tail(of surface: TerminalSurface) -> Tail? {
        guard let grid = surface.grid, grid.rowCount > 0, let last = grid.row(grid.rowCount - 1) else { return nil }
        let first = max(grid.rowCount - savedRows, 0)
        guard
            let text = grid.text(
                from: TerminalGridPoint(row: first, column: 0),
                to: TerminalGridPoint(row: grid.rowCount - 1, column: max(last.cells.count - 1, 0)))
        else { return nil }
        return Tail(text: text, isCut: first > 0, startsMidLine: first > 0 && grid.row(first)?.continues == true)
    }

    private static func contents(of tail: Tail) -> String {
        var lines = tail.text.components(separatedBy: "\n")
        if tail.startsMidLine, !lines.isEmpty { lines.removeFirst() }
        while let last = lines.last, last.allSatisfy(\.isWhitespace) { lines.removeLast() }
        if tail.isCut { lines.insert(cutNotice, at: 0) }
        return lines.map { $0 + "\n" }.joined()
    }

    private static func write(_ text: String, to file: URL, in folder: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let fd = open(file.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
            guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            try handle.write(contentsOf: Data(text.utf8))
            try handle.close()
        } catch {
            Log.warning("Couldn't save a run pane's output to \(file.path): \(error)", category: .panes)
            return false
        }
        prune(folder)
        return true
    }

    // Names start with the save's milliseconds, so the smallest are the oldest.
    private static func prune(_ folder: URL) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let saved = names.compactMap { name in Int(name.prefix { $0.isNumber }).map { (name, $0) } }
        for (name, _) in saved.sorted(by: { $0.1 < $1.1 }).dropLast(LaunchedPaneExits.kept) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }
}
