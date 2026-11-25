import Foundation
import TerminalKit

// What a pane's header names: its own name, a title its program sets, or the program and what it runs on.
enum PaneIdentity {
    enum Foreground: Equatable {
        case shell(arguments: [String]?)
        case job(group: pid_t, arguments: [String]?)
        // A host pane's foreground job is the local `ssh`, so only the title the host's shell sets names it.
        case remote
    }

    // A shell started at a prompt (`zsh`, `nix develop`) is the prompt, not a job.
    static func foreground(of surface: TerminalSurface) -> Foreground {
        guard let group = surface.foregroundProcessGroupID else { return .shell(arguments: nil) }
        let arguments = ProcessArguments.arguments(of: group)
        if ForegroundGroup.isShell(group) || arguments.map(ProcessArguments.isInteractiveShell) == true {
            return .shell(arguments: arguments)
        }
        return .job(group: group, arguments: arguments)
    }

    // `p_comm` names a program whose arguments the app cannot read (`sudo`).
    static func jobName(group: pid_t, arguments: [String]?) -> String? {
        arguments.flatMap(ProcessArguments.commandName(from:))
            ?? ForegroundGroup.system.command(group).flatMap(PaneCanvasController.jobName(fromCommand:))
    }

    static func header(
        of surface: TerminalSurface, named name: String?, directory: URL?, readsForeground: Bool,
        process: ProcessIcon
    ) -> PaneHeader.Content {
        let foreground = readsForeground ? foreground(of: surface) : .remote
        let program: String?
        switch foreground {
        case .shell, .remote: program = nil
        case .job(let group, let arguments): program = jobName(group: group, arguments: arguments)
        }
        return header(
            named: name, foreground: foreground, program: program, title: surface.title,
            directory: directory, process: process)
    }

    static func header(
        named name: String?, foreground: Foreground, program: String?, title: String?, directory: URL?,
        process: ProcessIcon
    ) -> PaneHeader.Content {
        let place = directory.map { PathDisplay.abbreviatingHome($0.path) }
        if let name, !name.isEmpty { return PaneHeader.Content(process: process, name: name, detail: nil) }
        switch foreground {
        case .shell(let arguments):
            let shell = arguments?.first.flatMap(ProcessArguments.programName(from:)) ?? "shell"
            return PaneHeader.Content(process: process, name: shell, detail: place)
        case .remote:
            let title = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !title.isEmpty { return PaneHeader.Content(process: process, name: title, detail: nil) }
            return PaneHeader.Content(process: process, name: "shell", detail: place)
        case .job(_, let arguments):
            let program = program ?? "program"
            if let title = ownTitle(title, program: program, directory: directory) {
                return PaneHeader.Content(process: process, name: title, detail: nil)
            }
            let operands = arguments.map(Self.operands(of:)) ?? []
            let detail = operands.isEmpty ? place : operands.joined(separator: " ")
            return PaneHeader.Content(process: process, name: program, detail: detail)
        }
    }

    // A title that only echoes the command line, or the folder a shell left behind, is not the program's own.
    static func ownTitle(_ title: String?, program: String, directory: URL?) -> String? {
        guard let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return nil }
        let firstWord = title.split(separator: " ").first.map(String.init) ?? title
        if ProcessArguments.programName(from: firstWord)?.lowercased() == program.lowercased() { return nil }
        if let directory {
            let echoes =
                [directory.path, PathDisplay.abbreviatingHome(directory.path)]
                + [PathDisplay.folderName(directory)].compactMap { $0 }
            if echoes.contains(where: title.hasSuffix) { return nil }
        }
        return title
    }

    static func operands(of arguments: [String]) -> [String] {
        var rest = Array(arguments.dropFirst())
        if let script = ProcessArguments.scriptName(in: arguments),
            let index = rest.firstIndex(where: { ProcessArguments.programName(from: $0) == script })
        {
            rest = Array(rest.dropFirst(index + 1))
        }
        return rest.map(PathDisplay.abbreviatingHome)
    }
}
