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

            let key: String
            let value: String
            if let equals = line.firstIndex(of: "=") {
                key = line[..<equals].trimmingCharacters(in: .whitespaces)
                let rawValue = String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
                value = ConfigText.unquote(rawValue)
            } else if line == Section.tabKey {
                key = line
                value = ""
            } else {
                continue
            }
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
        static let tabKey = "tab"

        let title: String
        var path: String?
        var tabs: [Workspace.Tab] = []
        var focus: Workspace.LaunchFocus?
        var env: [(key: String, value: String)] = []
        var carry: [String] = []

        mutating func set(key: String, value: String) {
            if key == Self.tabKey {
                tabs.append(Workspace.Tab(name: value.isEmpty ? nil : value))
                return
            }
            if key != "env", value.isEmpty { return }
            switch key {
            case "path": path = value
            case "main": setInCurrentTab(.main, value)
            case "right": setInCurrentTab(.right, value)
            case "bottom": setInCurrentTab(.bottom, value)
            case "focus": setFocus(value)
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

        private mutating func setInCurrentTab(_ region: Workspace.Region, _ command: String) {
            if tabs.isEmpty { tabs.append(Workspace.Tab()) }
            let index = tabs.count - 1
            switch region {
            case .main: tabs[index].main = command
            case .right: tabs[index].right = command
            case .bottom: tabs[index].bottom = command
            }
        }

        private mutating func setFocus(_ raw: String) {
            if tabs.isEmpty { tabs.append(Workspace.Tab()) }
            if focus != nil {
                Log.warning(
                    "Workspaces: `\(title)` has more than one `focus` — the last one wins", category: .workspace)
            }
            let region = Workspace.Region(rawValue: raw.lowercased())
            if region == nil {
                Log.warning(
                    "Workspaces: `\(title)` focus `\(raw)` isn't main/right/bottom — using main",
                    category: .workspace)
            }
            focus = Workspace.LaunchFocus(tab: tabs.count - 1, region: region ?? .main)
        }

        func build() -> Workspace? {
            guard let path, !path.isEmpty else {
                Log.warning(
                    "Workspaces: `\(title)` has no `path` — section dropped", category: .workspace)
                return nil
            }
            var envMap: [String: String] = [:]
            for entry in env { envMap[entry.key] = entry.value }
            return Workspace(
                title: title,
                path: URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true),
                tabs: tabs, focus: focus ?? .start, env: envMap, carry: carry)
        }
    }

}
