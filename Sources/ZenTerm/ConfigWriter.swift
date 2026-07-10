import Foundation

/// Edits the flat `~/.config/zen-term/config` file in place — the counterpart to
/// `GeneralConfigParser`. Unlike `WorkspacesWriter` (which appends whole `[Title]`
/// sections), `config` is `key = value`, so editing updates keys in place while
/// preserving comments, blank lines, and unknown keys verbatim. Round-trip:
/// `GeneralConfigParser.parse(apply(edits))` reflects every edit; untouched lines survive.
enum ConfigWriter {
    /// Apply scalar sets, scalar removals (reset-to-default), and/or a keymap override
    /// set to the `config` file. Reads the whole file and rewrites it atomically (an atomic
    /// write replaces, so there's no in-place append), preserving every unedited line.
    static func apply(
        scalars: [String: String] = [:],
        removals: Set<String> = [],
        keybinds: [Chord: KeyInterceptor.ReservedChord]? = nil,
        configRoot: URL = ConfigLoader.defaultRoot
    ) throws {
        try FileManager.default.createDirectory(at: configRoot, withIntermediateDirectories: true)
        let url = configRoot.appendingPathComponent("config")
        // If the file exists but can't be read, propagate — never treat an unreadable file as
        // empty, or the whole-file rewrite below would erase the user's config.
        let existing =
            FileManager.default.fileExists(atPath: url.path)
            ? try String(contentsOf: url, encoding: .utf8) : ""

        var lines = splitLines(existing)
        for (key, value) in scalars { setScalar(key, value, in: &lines) }
        for key in removals { removeScalar(key, in: &lines) }
        if let keybinds { applyKeybinds(keybinds, to: &lines) }

        var output = lines.joined(separator: "\n")
        if !output.isEmpty { output += "\n" }  // config files end with a trailing newline
        // Write to the symlink's target, not over the symlink — a config symlinked into a
        // dotfiles repo must keep pointing there.
        try output.write(to: url.resolvingSymlinksInPath(), atomically: true, encoding: .utf8)
    }

    /// Split into lines with the final trailing newline stripped, so a rejoin + single "\n"
    /// reproduces the file exactly (and an empty file yields no lines, not `[""]`).
    private static func splitLines(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var body = text
        if body.hasSuffix("\n") { body.removeLast() }
        return body.components(separatedBy: "\n")
    }

    // MARK: scalars

    private static func setScalar(_ key: String, _ value: String, in lines: inout [String]) {
        let rendered = "\(key) = \(value)"
        if let index = lines.firstIndex(where: { activeAssignmentKey($0) == key }) {
            // Preserve any trailing comment on the existing active line.
            if let comment = trailingComment(of: lines[index]) {
                lines[index] = "\(rendered)  \(comment)"
            } else {
                lines[index] = rendered
            }
            return
        }
        if let index = lines.firstIndex(where: { commentedAssignmentKey($0) == key }) {
            lines.insert(rendered, at: index + 1)
            return
        }
        lines.append(rendered)
    }

    private static func removeScalar(_ key: String, in lines: inout [String]) {
        lines.removeAll { activeAssignmentKey($0) == key }
    }

    // MARK: keybinds (implemented in Task 3)

    private static func applyKeybinds(
        _ keybinds: [Chord: KeyInterceptor.ReservedChord], to lines: inout [String]
    ) {
        // Task 3 fills this in.
    }

    // MARK: line classification

    /// The key of an uncommented `key = value` assignment line, else nil (comments, blanks,
    /// prose). Rejects a key containing whitespace so a prose line with a stray `=` never matches.
    static func activeAssignmentKey(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.hasPrefix("#"), let equals = trimmed.firstIndex(of: "=") else { return nil }
        let key = trimmed[..<equals].trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, !key.contains(where: \.isWhitespace) else { return nil }
        return key
    }

    /// The key of a commented-out assignment (`# key = default`), else nil. Same whitespace
    /// guard keeps a prose comment like `# switch = fast` from being read as a default.
    private static func commentedAssignmentKey(_ line: String) -> String? {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("#") else { return nil }
        trimmed.removeFirst()
        trimmed = trimmed.trimmingCharacters(in: .whitespaces)
        guard let equals = trimmed.firstIndex(of: "=") else { return nil }
        let key = trimmed[..<equals].trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, !key.contains(where: \.isWhitespace) else { return nil }
        return key
    }

    /// A trailing `# comment` on an active line (quote-aware — a `#` inside quotes isn't a
    /// comment), including the `#`; nil if none. Mirrors `GeneralConfigParser.stripComment`.
    private static func trailingComment(of line: String) -> String? {
        var inQuotes = false
        var previousWasSpace = true
        for index in line.indices {
            let character = line[index]
            if character == "\"" { inQuotes.toggle() }
            if character == "#", !inQuotes, previousWasSpace { return String(line[index...]) }
            previousWasSpace = character.isWhitespace
        }
        return nil
    }
}
