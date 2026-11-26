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
        if isPath(raw) { return folderName(ofPath: raw) }
        let shown = withoutStatus(raw)
        return shown.isEmpty ? directory.flatMap(PathDisplay.folderName) ?? "shell" : shown
    }

    private static func programName(in surface: TerminalSurface) -> String {
        if let program = PaneCanvasController.runningProgram(in: surface) { return program }
        let shell = surface.foregroundProcessGroupID
            .flatMap(ProcessArguments.arguments(of:))?.first.flatMap(ProcessArguments.programName(from:))
        return shell ?? "shell"
    }

    // An agent leads its title with a status glyph or a bracketed mark; a leading bracket or quote is the title's own.
    private static func withoutStatus(_ title: String) -> String {
        let leading = title.drop { character in
            guard let scalar = character.unicodeScalars.first else { return true }
            let category = scalar.properties.generalCategory
            return
                !(character.isLetter || character.isNumber || category == .openPunctuation
                || category == .initialPunctuation)
        }
        var shown = String(leading)
        for mark in ["[ ! ] ", "[ . ] "] where shown.hasPrefix(mark) { shown.removeFirst(mark.count) }
        return shown.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func pathStart(_ title: String) -> Substring {
        title.drop { !($0.isLetter || $0.isNumber || $0 == "~" || $0 == "/") }
    }

    private static func isPath(_ title: String) -> Bool {
        let start = pathStart(title)
        return start.hasPrefix("~") || start.hasPrefix("/")
    }

    private static func folderName(ofPath title: String) -> String {
        let path = pathStart(title).trimmingCharacters(in: .whitespacesAndNewlines)
        let last = path.split(separator: "/").last.map(String.init) ?? path
        return last.isEmpty || last == "~" ? PathDisplay.folderName(fromTitle: "~") : last
    }
}
