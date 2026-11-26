import Foundation
import TerminalKit

// How a pane is named: its header says what runs there and where, its tab says what the program reports.
enum PaneIdentity {
    struct Running: Equatable {
        var process: ProcessIcon
        var name: String
    }

    static func running(in surface: TerminalSurface) -> Running {
        Running(process: ProcessIcon.running(in: surface), name: programName(in: surface))
    }

    static func header(named name: String?, running: Running, directory: URL?) -> PaneHeader.Content {
        PaneHeader.Content(
            process: running.process,
            name: name.flatMap { $0.isEmpty ? nil : $0 } ?? running.name,
            path: directory.map { PathDisplay.abbreviatingHome($0.path) })
    }

    static func tabTitle(title: String?, directory: URL?) -> String {
        let raw = title ?? ""
        if isPath(raw, in: directory) { return folderName(ofPath: raw) }
        let shown = withoutStatus(raw)
        return shown.isEmpty ? directory.flatMap(PathDisplay.folderName) ?? "shell" : shown
    }

    private static func programName(in surface: TerminalSurface) -> String {
        if let program = PaneCanvasController.runningProgram(in: surface) { return program }
        guard let group = surface.foregroundProcessGroupID else { return "shell" }
        if let name = ProcessArguments.arguments(of: group)?.first.flatMap(ProcessArguments.programName(from:)) {
            return name
        }
        return ForegroundGroup.isShell(group) ? "shell" : ProcessIcon.unknown.name.lowercased()
    }

    // An agent leads its title with a word of bare symbols (`✳`, a spinner frame) or a bracketed mark; a command's `./` is its own.
    private static func withoutStatus(_ title: String) -> String {
        var shown = title.trimmingCharacters(in: .whitespacesAndNewlines)
        for mark in ["[ ! ] ", "[ . ] "] where shown.hasPrefix(mark) { shown.removeFirst(mark.count) }
        let words = shown.split(separator: " ", maxSplits: 1)
        if words.count == 2, !words[0].contains(where: { $0.isLetter || $0.isNumber }) { shown = String(words[1]) }
        for mark in ["[ ! ] ", "[ . ] "] where shown.hasPrefix(mark) { shown.removeFirst(mark.count) }
        return shown.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func pathStart(_ title: String) -> Substring {
        title.drop { !($0.isLetter || $0.isNumber || $0 == "~" || $0 == "/" || $0 == ".") }
    }

    // A shell titles its prompt with the folder and a running job with its command line, which can start with a path too.
    private static func isPath(_ title: String, in directory: URL?) -> Bool {
        let start = pathStart(title).trimmingCharacters(in: .whitespacesAndNewlines)
        guard start.hasPrefix("~") || start.hasPrefix("/") else { return false }
        guard start.contains(where: \.isWhitespace) else { return true }
        guard let directory else { return false }
        return [directory.path, PathDisplay.abbreviatingHome(directory.path)].contains { $0.hasSuffix(start) }
    }

    private static func folderName(ofPath title: String) -> String {
        let path = pathStart(title).trimmingCharacters(in: .whitespacesAndNewlines)
        let last = path.split(separator: "/").last.map(String.init) ?? path
        return last.isEmpty || last == "~" ? PathDisplay.folderName(fromTitle: "~") : last
    }
}
