import CoreGraphics
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
        floatUpserts: [ToolFloat] = [],
        floatRemovals: Set<String> = [],
        configRoot: URL = ConfigLoader.defaultRoot
    ) throws {
        try FileManager.default.createDirectory(at: configRoot, withIntermediateDirectories: true)
        let url = configRoot.appendingPathComponent("config")
        let existing = try ConfigFileIO.readExistingOrEmpty(url)

        var lines = splitLines(existing)
        for (key, value) in scalars { setScalar(key, value, in: &lines) }
        for key in removals { removeScalar(key, in: &lines) }
        if let keybinds { applyKeybinds(keybinds, to: &lines) }
        if !floatUpserts.isEmpty || !floatRemovals.isEmpty {
            applyFloats(upserts: floatUpserts, removals: floatRemovals, in: &lines)
        }

        var output = lines.joined(separator: "\n")
        if !output.isEmpty { output += "\n" }  // config files end with a trailing newline
        try ConfigFileIO.writePreservingSymlink(output, to: url)
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
            if let comment = ConfigText.trailingComment(of: lines[index]) {
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

    /// Regenerate the reserved `keybind =` block from the desired keymap. Diffs per *action*: an
    /// action whose chord set differs from its `KeymapDefaults` set emits a line for *every* one of
    /// its chords — including any that happen to coincide with a default — because the assembler
    /// drops an action's defaults the moment it sees a user line for it, then rebuilds from exactly
    /// the lines present. (A per-chord diff would silently drop a default-valued chord and let the
    /// assembler restore the whole default set — losing a narrowing edit.) An action at its default
    /// set emits nothing. Preserves existing `keybind = toggle_float:…` lines (float-owned, edited
    /// only via `float =`) and drops every other existing `keybind =` line. The block lands where
    /// the first `keybind =` line was; if there were none, after the `Keybinds` header, else appended.
    private static func applyKeybinds(
        _ keybinds: [Chord: KeyInterceptor.ReservedChord], to lines: inout [String]
    ) {
        let floatBinds = lines.filter(isFloatKeybindLine)

        // Per-action diff: emit a chord's line when that action's whole desired set differs from its
        // default set. (`ReservedChord` has associated values so it can't key a dictionary — compare
        // the two sets by filtering. n is tiny.) Iterating every chord of a differing action emits
        // all of them; an action at its defaults emits nothing.
        let overrides =
            keybinds
            .filter { _, action in chords(of: action, in: keybinds) != chords(of: action, in: KeymapDefaults.map) }
            .map { chord, action in "keybind = \(action.actionToken)=\(chord.configToken)" }
            .sorted()
        let block = floatBinds + overrides

        var result: [String] = []
        var inserted = false
        for line in lines {
            if isKeybindLine(line) {
                if !inserted {
                    result.append(contentsOf: block)
                    inserted = true
                }
                continue  // drop every existing keybind line (block re-adds the ones we keep)
            }
            result.append(line)
        }
        if !inserted, !block.isEmpty {
            if let headerIndex = result.firstIndex(where: { $0.contains("─── Keybinds") }) {
                result.insert(contentsOf: block, at: headerIndex + 1)
            } else {
                if let last = result.last, !last.isEmpty { result.append("") }
                result.append(contentsOf: block)
            }
        }
        lines = result
    }

    /// The set of chords bound to `action` in `map` — for the per-action diff in `applyKeybinds`.
    private static func chords(
        of action: KeyInterceptor.ReservedChord, in map: [Chord: KeyInterceptor.ReservedChord]
    ) -> Set<Chord> {
        Set(map.filter { $0.value == action }.map(\.key))
    }

    private static func isKeybindLine(_ line: String) -> Bool { activeAssignmentKey(line) == "keybind" }

    private static func isFloatKeybindLine(_ line: String) -> Bool {
        guard isKeybindLine(line), let equals = line.firstIndex(of: "=") else { return false }
        let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
        return value.hasPrefix("toggle_float:")
    }

    // MARK: floats

    /// Serialize a `ToolFloat` into its full `float = …` line — the inverse of `ToolFloatParser`,
    /// round-tripping its quote-aware `field:value` grammar. The required fields (`id`, `key`,
    /// `command`) are always emitted; an optional field is omitted when it equals the parser's default
    /// (shared via `ToolFloatParser`, so the two halves can't drift), keeping a plain float's line
    /// lean. A value with whitespace or a `#` is quoted — the same rule `WorkspacesWriter` uses — so
    /// the parser's comment strip and whitespace tokenizer don't split it.
    static func serializeFloat(_ float: ToolFloat) -> String {
        var tokens = ["id:\(quotedValue(float.id))", "key:\(float.toggle.configToken)"]
        if float.title != ToolFloatParser.defaultTitle(forID: float.id) {
            tokens.append("title:\(quotedValue(float.title))")
        }
        if float.icon != ToolFloatParser.defaultIcon { tokens.append("icon:\(quotedValue(float.icon))") }
        tokens.append("command:\(quotedValue(float.command))")
        if let dir = float.dir { tokens.append("dir:\(quotedValue(PathDisplay.abbreviatingHome(dir.path)))") }
        if float.widthFraction != ToolFloatParser.defaultFraction {
            tokens.append("width:\(ToolFloatParser.fractionText(float.widthFraction))")
        }
        if float.heightFraction != ToolFloatParser.defaultFraction {
            tokens.append("height:\(ToolFloatParser.fractionText(float.heightFraction))")
        }
        if float.requiresGitRepo { tokens.append("git:true") }
        if float.persist != ToolFloatParser.defaultPersist { tokens.append("persist:\(float.persist.rawValue)") }
        return "float = " + tokens.joined(separator: " ")
    }

    /// Replace each upsert's `float =` line in place (matched by `id:`, preserving any trailing
    /// comment), or insert it after the last existing float line (else append). Removals run first,
    /// dropping every float line whose id is in the set. Only float lines are touched; comments,
    /// blanks, and every other key survive verbatim.
    private static func applyFloats(upserts: [ToolFloat], removals: Set<String>, in lines: inout [String]) {
        if !removals.isEmpty {
            lines.removeAll { floatID(of: $0).map(removals.contains) ?? false }
        }
        for float in upserts {
            let rendered = serializeFloat(float)
            if let index = lines.firstIndex(where: { floatID(of: $0) == float.id }) {
                if let comment = ConfigText.trailingComment(of: lines[index]) {
                    lines[index] = "\(rendered)  \(comment)"
                } else {
                    lines[index] = rendered
                }
            } else if let lastFloat = lines.lastIndex(where: { floatID(of: $0) != nil }) {
                lines.insert(rendered, at: lastFloat + 1)  // group with the existing float lines
            } else {
                lines.append(rendered)
            }
        }
    }

    /// The `id:` of an active `float =` line, else nil (not a float line, or its id is missing). Reads
    /// through `ToolFloatParser.fields` so line-matching uses the very tokenizer the parser does.
    private static func floatID(of line: String) -> String? {
        guard activeAssignmentKey(line) == "float", let equals = line.firstIndex(of: "=") else { return nil }
        let value = ConfigText.stripComment(String(line[line.index(after: equals)...]))
        let id = ToolFloatParser.fields(value)["id"] ?? ""
        return id.isEmpty ? nil : id
    }

    /// Quote a value that carries whitespace or a `#` so the parser's comment strip and tokenizer
    /// keep it intact; leave a bare token bare. Values never contain a `"` — the form rejects them
    /// (the grammar has no escape).
    private static func quotedValue(_ value: String) -> String {
        let needsQuoting = value.contains("#") || value.contains(where: \.isWhitespace)
        return needsQuoting ? "\"\(value)\"" : value
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

}
