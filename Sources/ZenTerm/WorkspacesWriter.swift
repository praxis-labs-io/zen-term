import Foundation

/// Serializes a `Workspace` back to its `[Title]` INI section and appends it to the
/// `workspaces` file — the inverse of `WorkspacesParser`, and the app's only config writer.
/// A round-trip (`serialize` → `WorkspacesParser.parse`) reproduces an equal `Workspace`.
enum WorkspacesWriter {
    enum WriteError: Error, LocalizedError {
        /// The file already has a section with this title (would shadow it under last-wins).
        case titleExists(String)

        var errorDescription: String? {
            switch self {
            case .titleExists(let title): return "A workspace named “\(title)” already exists."
            }
        }
    }

    /// Keys are padded to this width before ` = `, aligning the `=` columns within a section to
    /// match the hand-written house style in `docs/config/workspaces` (longest key is `bottom`).
    private static let keyColumnWidth = 6

    /// Render a workspace as one `[Title]` section: aligned `key = value` lines in the same field
    /// order as `docs/config/workspaces`, absent fields omitted (the parser treats an empty value
    /// as absent), values quoted when they contain whitespace or a `#` (so the parser doesn't
    /// truncate a comment or lose spacing), and env keys sorted for deterministic output.
    static func serialize(_ ws: Workspace) -> String {
        var lines = ["[\(ws.title)]"]
        func add(_ key: String, _ rendered: String) {
            // Pad to the column width, but never truncate a key that's wider than it.
            let paddedKey = key.padding(toLength: max(key.count, keyColumnWidth), withPad: " ", startingAt: 0)
            lines.append("\(paddedKey) = \(rendered)")
        }
        add("path", quoted(abbreviatingHome(ws.path.path)))
        if let main = ws.main { add("main", quoted(main)) }
        if let right = ws.right { add("right", quoted(right)) }
        if let bottom = ws.bottom { add("bottom", quoted(bottom)) }
        if ws.focus != .main { add("focus", ws.focus.rawValue) }  // .main is the parser default
        for key in ws.env.keys.sorted() {
            // The parser splits an env line on the first `=` for the KEY, then unquotes the VALUE
            // — so quote only the value part, never the `KEY=` prefix.
            add("env", "\(key)=\(quoted(ws.env[key] ?? ""))")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Append a workspace section to the `workspaces` file, creating the config directory and
    /// file on first write. Reads the whole file and rewrites it (atomic write replaces, so it
    /// can't append in place) — preserving every hand-written comment and section verbatim, with
    /// a blank line separating the new section. Throws `titleExists` rather than shadowing a
    /// section that already carries this title.
    static func append(_ ws: Workspace, configRoot: URL = ConfigLoader.defaultRoot) throws {
        try FileManager.default.createDirectory(at: configRoot, withIntermediateDirectories: true)
        let url = configRoot.appendingPathComponent("workspaces")
        // If the file exists but can't be read, propagate the error — never treat an unreadable
        // file as empty, or the whole-file rewrite below would erase every existing workspace.
        let existing =
            FileManager.default.fileExists(atPath: url.path)
            ? try String(contentsOf: url, encoding: .utf8) : ""
        guard !WorkspacesParser.parse(existing).contains(where: { $0.title == ws.title }) else {
            throw WriteError.titleExists(ws.title)
        }
        let separator: String
        if existing.isEmpty {
            separator = ""
        } else if existing.hasSuffix("\n") {
            separator = "\n"  // one more newline → a blank line before the new section
        } else {
            separator = "\n\n"
        }
        // Write to the symlink's target, not over the symlink — a config symlinked into a dotfiles
        // repo must keep pointing there (atomic write would otherwise replace it with a plain file).
        try (existing + separator + serialize(ws))
            .write(to: url.resolvingSymlinksInPath(), atomically: true, encoding: .utf8)
    }

    /// Wrap a value in double quotes when it contains whitespace or a `#`, so it survives the
    /// parser's comment-stripping and whitespace-trimming; otherwise leave it bare. Values never
    /// contain a `"` (the form rejects them — the format has no escape mechanism).
    private static func quoted(_ value: String) -> String {
        let needsQuoting = value.contains("#") || value.contains(where: \.isWhitespace)
        return needsQuoting ? "\"\(value)\"" : value
    }

    /// Re-collapse the home prefix to `~` so a serialized `path` matches the tilde house style in
    /// `docs/config/workspaces` (the parser expands it back, so the round-trip is unchanged).
    private static func abbreviatingHome(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}
