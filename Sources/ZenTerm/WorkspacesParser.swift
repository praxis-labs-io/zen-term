import AppLog
import Foundation

// Best-effort: unknown keys are ignored, bad entries logged and skipped, and nothing throws.
enum WorkspacesParser {
    static func parse(_ text: String) -> [Workspace] {
        var workspaces: [Workspace] = []
        var current: Section?

        func flush() {
            defer { current = nil }
            guard let workspace = current?.build() else { return }
            workspaces.removeAll { $0.title == workspace.title }
            workspaces.append(workspace)
        }

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = ConfigText.stripComment(String(rawLine)).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            if line.hasPrefix("[") && line.hasSuffix("]") {
                flush()
                let title = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                if title.isEmpty {
                    Log.warning(
                        "Workspaces: an empty `[…]` section header — ignored", category: .workspace)
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
                Log.warning(
                    "Workspaces: `\(key)` appears before any [section] — ignored", category: .workspace)
                continue
            }
            current?.set(key: key, value: value)
        }
        flush()
        return workspaces
    }

    private struct Section {
        let title: String
        var path: String?
        var main: String?
        var right: String?
        var bottom: String?
        var focusRaw: String?
        var env: [(key: String, value: String)] = []
        var carry: [String] = []

        mutating func set(key: String, value: String) {
            if key != "env", value.isEmpty { return }
            switch key {
            case "path": path = value
            case "main": main = value
            case "right": right = value
            case "bottom": bottom = value
            case "focus": focusRaw = value
            case "env":
                guard let equals = value.firstIndex(of: "=") else {
                    Log.warning(
                        "Workspaces: `\(title)` env entry `\(value)` isn't KEY=VALUE — skipped",
                        category: .workspace)
                    return
                }
                let name = String(value[..<equals]).trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else {
                    Log.warning(
                        "Workspaces: `\(title)` env entry `\(value)` has an empty key — skipped",
                        category: .workspace)
                    return
                }
                let raw = String(value[value.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
                env.append((name, ConfigText.unquote(raw)))
            case "carry":
                let entry = value.hasSuffix("/") ? String(value.dropLast()) : value
                guard !entry.hasPrefix("/"), !entry.hasPrefix("~"),
                    !entry.split(separator: "/").contains("..")
                else {
                    Log.warning(
                        "Workspaces: `\(title)` carry `\(value)` leaves the workspace — skipped",
                        category: .workspace)
                    return
                }
                carry.append(entry)
            default:
                break
            }
        }

        func build() -> Workspace? {
            guard let path, !path.isEmpty else {
                Log.warning(
                    "Workspaces: `\(title)` has no `path` — section dropped", category: .workspace)
                return nil
            }
            let focus = focusRaw.flatMap { Workspace.Region(rawValue: $0.lowercased()) } ?? .main
            if let focusRaw, Workspace.Region(rawValue: focusRaw.lowercased()) == nil {
                Log.warning(
                    "Workspaces: `\(title)` focus `\(focusRaw)` isn't main/right/bottom — using main",
                    category: .workspace)
            }
            var envMap: [String: String] = [:]
            for entry in env { envMap[entry.key] = entry.value }
            return Workspace(
                title: title,
                path: URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true),
                main: main, right: right, bottom: bottom, focus: focus, env: envMap, carry: carry)
        }
    }

}
