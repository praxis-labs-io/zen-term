import Foundation
import TerminalKit

// What a pane's header calls it: its own name, else a title its running program sets, else its folder.
enum PaneIdentity {
    static func label(of surface: TerminalSurface, named name: String?, directory: URL?, otherwise: String = "shell")
        -> PaneHeader.Label
    {
        label(
            named: name, title: surface.title, program: PaneCanvasController.runningProgram(in: surface),
            directory: directory, otherwise: otherwise)
    }

    // A tool float has no folder of its own, so it passes its name as the last resort.
    static func label(
        named name: String?, title: String?, program: String?, directory: URL?, otherwise: String = "shell"
    ) -> PaneHeader.Label {
        if let name, !name.isEmpty { return PaneHeader.Label(text: name) }
        if let program, let title = ownTitle(title, of: program) { return PaneHeader.Label(text: title) }
        guard let directory else { return PaneHeader.Label(text: otherwise) }
        return PaneHeader.Label(text: PathDisplay.abbreviatingHome(directory.path), isPath: true)
    }

    // The shell titles a pane with the command line it runs, which only repeats the program's name.
    private static func ownTitle(_ title: String?, of program: String) -> String? {
        guard let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return nil }
        let firstWord = title.split(separator: " ").first.map(String.init) ?? title
        return ProcessArguments.programName(from: firstWord)?.lowercased() == program.lowercased() ? nil : title
    }
}
