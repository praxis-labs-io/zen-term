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
        add("path", quoted(PathDisplay.abbreviatingHome(ws.path.path)))
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
        let existing = try ConfigFileIO.readExistingOrEmpty(url)
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
        try ConfigFileIO.writePreservingSymlink(existing + separator + serialize(ws), to: url)
    }

    /// Replace the `[originalTitle]` section with `ws` (renamed when the titles differ), rewriting
    /// that section's header + `key = value` lines from the model in place. Every *other* section and
    /// the file's shape around this one — comments, ordering, blank separators — survives verbatim;
    /// comments *inside* the edited section are not preserved, since its body is regenerated from the
    /// structured fields. Falls back to `append` when `originalTitle` isn't present (so a stale edit
    /// still lands). Throws `titleExists` when a rename would collide with a *different* section
    /// already carrying the new title (last-wins would shadow it).
    static func update(_ ws: Workspace, originalTitle: String, configRoot: URL = ConfigLoader.defaultRoot) throws {
        let url = configRoot.appendingPathComponent("workspaces")
        let existing = try ConfigFileIO.readExistingOrEmpty(url)
        if ws.title != originalTitle,
            WorkspacesParser.parse(existing).contains(where: { $0.title == ws.title })
        {
            throw WriteError.titleExists(ws.title)
        }
        var lines = existing.components(separatedBy: "\n")
        guard let span = locateSection(titled: originalTitle, in: lines) else {
            try append(ws, configRoot: configRoot)  // original gone — treat as a fresh add
            return
        }
        // `serialize` ends with a trailing "\n"; drop that empty tail so we splice bare body lines.
        let body = Array(serialize(ws).components(separatedBy: "\n").dropLast())
        lines.replaceSubrange(span.start..<span.bodyEnd, with: body)
        try FileManager.default.createDirectory(at: configRoot, withIntermediateDirectories: true)
        try ConfigFileIO.writePreservingSymlink(lines.joined(separator: "\n"), to: url)
    }

    /// Drop the `[title]` section, preserving every other section, comment, and the file's shape.
    /// Also consumes the one blank separator that trailed the section so removing a middle section
    /// doesn't leave a double blank line. A no-op when no section carries that title.
    static func remove(title: String, configRoot: URL = ConfigLoader.defaultRoot) throws {
        let url = configRoot.appendingPathComponent("workspaces")
        let existing = try ConfigFileIO.readExistingOrEmpty(url)
        var lines = existing.components(separatedBy: "\n")
        guard let span = locateSection(titled: title, in: lines) else { return }
        var end = span.bodyEnd
        // Swallow blank separator lines after the body (but not comments — those document the next
        // section) so the neighbours close up cleanly. Trim newlines too, so a stray `\r` from a
        // CRLF-edited file still reads as blank.
        while end < span.nextHeader, lines[end].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            end += 1
        }
        lines.removeSubrange(span.start..<end)
        try ConfigFileIO.writePreservingSymlink(lines.joined(separator: "\n"), to: url)
    }

    /// Exchange the file positions of the `[title]` and `[other]` sections — the write behind ⌥↑/⌥↓
    /// in Settings → Workspaces. Section order *is* picker order (`WorkspacesParser` returns sections
    /// in the order it meets them), so moving the block is the same edit a hand-edit makes, and no
    /// `order` key has to exist alongside a position that already means something.
    ///
    /// Exchanges the two *named* blocks rather than moving one past whatever block is adjacent: a
    /// duplicate title is shadowed under last-wins, so the two rows a user sees side by side can have
    /// a section between them that has no row at all. A no-op when either title is absent (a stale
    /// row), which leaves the file for the reload to correct.
    static func swap(_ title: String, with other: String, configRoot: URL = ConfigLoader.defaultRoot) throws {
        let url = configRoot.appendingPathComponent("workspaces")
        var lines = try ConfigFileIO.readExistingOrEmpty(url).components(separatedBy: "\n")
        guard let a = locateBlock(titled: title, in: lines),
            let b = locateBlock(titled: other, in: lines)
        else { return }
        // Splice the later block first: replacing the earlier one with a block of a different length
        // shifts every index after it, and the second range would then land mid-section.
        let (earlier, later) = a.start < b.start ? (a, b) : (b, a)
        let earlierBlock = Array(lines[earlier.start..<earlier.end])
        let laterBlock = Array(lines[later.start..<later.end])
        lines.replaceSubrange(later.start..<later.end, with: earlierBlock)
        lines.replaceSubrange(earlier.start..<earlier.end, with: laterBlock)
        try ConfigFileIO.writePreservingSymlink(lines.joined(separator: "\n"), to: url)
    }

    /// The movable block for `title`: its section body, plus any contiguous comment run sitting
    /// directly on the header. A comment touching a header documents that workspace and travels with
    /// it; a blank line below a comment detaches it, which is what keeps the file's top banner at the
    /// top. Blank separators sit outside every block, so they stay where they are and a swap can
    /// neither double nor eat one.
    ///
    /// Two distinct titles always yield disjoint blocks: `locateSection` ends a body before any
    /// trailing comment, so walking up from the next header stops at the previous section's last
    /// `key = value` line rather than reaching into it.
    private static func locateBlock(titled title: String, in lines: [String]) -> (start: Int, end: Int)? {
        guard let span = locateSection(titled: title, in: lines) else { return nil }
        var start = span.start
        // Trim newlines as well as spaces, so a `\r` from a CRLF-edited file doesn't hide a comment.
        while start > 0, lines[start - 1].trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#") {
            start -= 1
        }
        return (start, span.bodyEnd)
    }

    /// Locate the `[title]` section within `lines`: the header index (`start`), the index just past
    /// its last `key = value` line (`bodyEnd`, excluding trailing blank/comment lines that belong to
    /// the separator or the next section), and the next header index or end-of-file (`nextHeader`).
    /// Matches on the comment-stripped, trimmed header like the parser; the last section wins a
    /// duplicated title, mirroring `WorkspacesParser`'s last-wins rule.
    private static func locateSection(
        titled title: String, in lines: [String]
    ) -> (start: Int, bodyEnd: Int, nextHeader: Int)? {
        // Trim newlines as well as spaces, so a stray `\r` from a CRLF-edited file (we split on
        // "\n") doesn't defeat the `]` suffix check and hide the header.
        func headerTitle(_ line: String) -> String? {
            let stripped = ConfigText.stripComment(line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard stripped.hasPrefix("["), stripped.hasSuffix("]") else { return nil }
            return String(stripped.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        }
        guard let start = lines.lastIndex(where: { headerTitle($0) == title }) else { return nil }
        var nextHeader = lines.count
        var index = start + 1
        while index < lines.count {
            if headerTitle(lines[index]) != nil {
                nextHeader = index
                break
            }
            index += 1
        }
        var bodyEnd = nextHeader
        while bodyEnd > start + 1,
            ConfigText.stripComment(lines[bodyEnd - 1]).trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
        {
            bodyEnd -= 1
        }
        return (start, bodyEnd, nextHeader)
    }

    /// Wrap a value in double quotes when it contains whitespace or a `#`, so it survives the
    /// parser's comment-stripping and whitespace-trimming; otherwise leave it bare. Values never
    /// contain a `"` (the form rejects them — the format has no escape mechanism).
    private static func quoted(_ value: String) -> String {
        let needsQuoting = value.contains("#") || value.contains(where: \.isWhitespace)
        return needsQuoting ? "\"\(value)\"" : value
    }

}
