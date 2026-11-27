import Foundation

// A hooks file in Claude Code's settings shape, edited only under `hooks.SessionStart` where an entry runs ZenTerm's hook.
struct SessionStartHooks {
    static let hookFileName = "zenterm-context.sh"

    private(set) var root: [String: Any]

    static func read(at url: URL) throws(SetupError) -> SessionStartHooks {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile {
            return SessionStartHooks(root: [:])
        } catch {
            throw .unreadable(url, error)
        }
        if String(decoding: data, as: UTF8.self).allSatisfy(\.isWhitespace) { return SessionStartHooks(root: [:]) }
        guard let object = try? JSONSerialization.jsonObject(with: data), let root = object as? [String: Any] else {
            throw .malformed(url, "isn't a JSON object")
        }
        let settings = SessionStartHooks(root: root)
        _ = try settings.sessionStart(at: url)
        return settings
    }

    func write(to url: URL) throws(SetupError) {
        let target = url.resolvingSymlinksInPath()
        do {
            var data = try JSONSerialization.data(
                withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            data.append(0x0A)
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: target, options: .atomic)
        } catch {
            throw .unwritable(target, error)
        }
    }

    func isRegistered(command: String) -> Bool {
        var copy = self
        return !copy.register(command: command)
    }

    func hasOwnEntry() -> Bool {
        sessionStartGroups.contains {
            (($0 as? [String: Any])?["hooks"] as? [Any])?.contains(where: Self.isOwn) == true
        }
    }

    mutating func register(command: String) -> Bool {
        let own: [String: Any] = ["hooks": [["type": "command", "command": command, "timeout": Self.timeout]]]
        var placed = false
        var groups: [Any] = []
        for group in sessionStartGroups {
            guard var fields = group as? [String: Any], let hooks = fields["hooks"] as? [Any] else {
                groups.append(group)
                continue
            }
            let kept = hooks.filter { !Self.isOwn($0) }
            if kept.count == hooks.count {
                groups.append(group)
            } else if kept.isEmpty {
                if !placed { groups.append(own) }
                placed = true
            } else {
                fields["hooks"] = kept
                groups.append(fields)
            }
        }
        if !placed { groups.append(own) }
        return replaceSessionStart(with: groups)
    }

    mutating func unregister() -> Bool {
        var groups: [Any] = []
        for group in sessionStartGroups {
            guard var fields = group as? [String: Any], let hooks = fields["hooks"] as? [Any] else {
                groups.append(group)
                continue
            }
            let kept = hooks.filter { !Self.isOwn($0) }
            if kept.count == hooks.count {
                groups.append(group)
            } else if !kept.isEmpty {
                fields["hooks"] = kept
                groups.append(fields)
            }
        }
        return replaceSessionStart(with: groups)
    }

    // Recognized by the script's file name, so an entry wired by hand before `zen setup` is adopted, not duplicated.
    private static func isOwn(_ hook: Any) -> Bool {
        ((hook as? [String: Any])?["command"] as? String)?.contains("/\(hookFileName)") == true
    }

    private static let timeout = 5

    private var sessionStartGroups: [Any] {
        (root["hooks"] as? [String: Any])?["SessionStart"] as? [Any] ?? []
    }

    private func sessionStart(at url: URL) throws(SetupError) -> [Any] {
        guard let hooks = root["hooks"] else { return [] }
        guard let events = hooks as? [String: Any] else {
            throw .malformed(url, "has a \"hooks\" that isn't an object")
        }
        guard let groups = events["SessionStart"] else { return [] }
        guard let list = groups as? [Any] else {
            throw .malformed(url, "has a \"hooks.SessionStart\" that isn't a list")
        }
        return list
    }

    private mutating func replaceSessionStart(with groups: [Any]) -> Bool {
        guard !NSArray(array: sessionStartGroups).isEqual(to: groups) else { return false }
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        hooks["SessionStart"] = groups.isEmpty ? nil : groups
        root["hooks"] = hooks.isEmpty ? nil : hooks
        return true
    }
}
