import Foundation

/// Parses `~/.config/zen-term/workspaces` into `[Workspace]`. INI-style: each `[Title]`
/// section is one workspace, with `key = value` lines (`path`, `main`, `right`, `bottom`,
/// `focus`, and repeatable `env`). Best-effort, symmetric with the other config parsers:
/// unknown keys are ignored, a section missing the required `path` is logged and dropped, a
/// malformed `env` entry is skipped, a value may be wrapped in quotes, and nothing throws.
enum WorkspacesParser {
    static func parse(_ text: String) -> [Workspace] {
        var workspaces: [Workspace] = []
        var current: Section?

        func flush() {
            defer { current = nil }
            guard let workspace = current?.build() else { return }
            workspaces.removeAll { $0.title == workspace.title }  // last section of a title wins
            workspaces.append(workspace)
        }

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = ConfigText.stripComment(String(rawLine)).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            if line.hasPrefix("[") && line.hasSuffix("]") {
                flush()  // a header closes the previous section
                let title = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                if title.isEmpty {
                    NSLog("Workspaces: an empty `[…]` section header — ignored")
                    continue
                }
                current = Section(title: title)
                continue
            }

            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            let rawValue = String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
            let value = ConfigText.unquote(rawValue)
            guard current != nil else {
                NSLog("Workspaces: `\(key)` appears before any [section] — ignored")
                continue
            }
            current?.set(key: key, value: value)
        }
        flush()  // finalize the trailing section
        return workspaces
    }

    /// A section accumulated line by line, then resolved into a `Workspace` by `build()`.
    private struct Section {
        let title: String
        var path: String?
        var main: String?
        var right: String?
        var bottom: String?
        var focusRaw: String?
        var env: [(key: String, value: String)] = []

        mutating func set(key: String, value: String) {
            if key != "env", value.isEmpty { return }  // `right =` (empty) → absent, not a "" command
            switch key {
            case "path": path = value
            case "main": main = value
            case "right": right = value
            case "bottom": bottom = value
            case "focus": focusRaw = value
            case "env":
                guard let equals = value.firstIndex(of: "=") else {
                    NSLog("Workspaces: `\(title)` env entry `\(value)` isn't KEY=VALUE — skipped")
                    return
                }
                let name = String(value[..<equals]).trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else {
                    NSLog("Workspaces: `\(title)` env entry `\(value)` has an empty key — skipped")
                    return
                }
                // Trim + unquote the value so `env = KEY= v` and `env = KEY="a b"` behave like the
                // rest of the parser (whitespace-trimmed, quotes optional) instead of keeping them literal.
                let raw = String(value[value.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
                env.append((name, ConfigText.unquote(raw)))
            default:
                break  // unknown key — ignored
            }
        }

        func build() -> Workspace? {
            guard let path, !path.isEmpty else {
                NSLog("Workspaces: `\(title)` has no `path` — section dropped")
                return nil
            }
            let focus = focusRaw.flatMap { Workspace.Region(rawValue: $0.lowercased()) } ?? .main
            if let focusRaw, Workspace.Region(rawValue: focusRaw.lowercased()) == nil {
                NSLog("Workspaces: `\(title)` focus `\(focusRaw)` isn't main/right/bottom — using main")
            }
            var envMap: [String: String] = [:]
            for entry in env { envMap[entry.key] = entry.value }  // last wins for a repeated key
            return Workspace(
                title: title,
                path: URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true),
                main: main, right: right, bottom: bottom, focus: focus, env: envMap)
        }
    }

}
