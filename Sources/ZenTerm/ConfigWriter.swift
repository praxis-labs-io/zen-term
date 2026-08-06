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
        keybinds: KeymapOverrides? = nil,
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

    // MARK: keybinds

    /// Regenerate the reserved `keybind =` block from the desired keymap. Diffs per *action*: an
    /// action whose chord set differs from its `KeymapDefaults` set emits a line for *every* one of
    /// its chords — including any that happen to coincide with a default — because the assembler
    /// drops an action's defaults the moment it sees a user line for it, then rebuilds from exactly
    /// the lines present. (A per-chord diff would silently drop a default-valued chord and let the
    /// assembler restore the whole default set — losing a narrowing edit.) An action at its default
    /// set emits nothing. Preserves existing `keybind = toggle_float:…` lines (float-owned, edited
    /// only via `float =`) and drops every other existing `keybind =` line. The block lands where
    /// the first `keybind =` line was; if there were none, after the `Keybinds` header, else appended.
    ///
    /// An unbound action emits `= none` and needs no exclusion from the chord diff above: it holds
    /// no chord, so it never enters that loop. Emitted even when the action ships with no default
    /// chord and the line is therefore inert, because the user wrote it and this block is the only
    /// place it lives (ZEN-368).
    private static func applyKeybinds(_ keybinds: KeymapOverrides, to lines: inout [String]) {
        let floatBinds = lines.filter(isFloatKeybindLine)

        // Per-action diff: emit a chord's line when that action's whole desired set differs from its
        // default set. (`ReservedChord` has associated values so it can't key a dictionary — compare
        // the two sets by filtering. n is tiny.) Iterating every chord of a differing action emits
        // all of them; an action at its defaults emits nothing.
        let rebinds =
            keybinds.binds
            .filter { _, action in keybinds.chords(of: action) != chords(of: action, in: KeymapDefaults.map) }
            .map { chord, action in "keybind = \(action.actionToken)=\(chord.configToken)" }
        let unbinds = keybinds.unbound.map { "keybind = \($0.actionToken)=none" }
        let block = floatBinds + (rebinds + unbinds).sorted()

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

    /// The set of chords bound to `action` in `map`: the `KeymapDefaults` half of the per-action
    /// diff in `applyKeybinds`. The desired half is `KeymapOverrides.chords(of:)`.
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
    /// round-tripping its quote-aware `field:value` grammar. The required fields (`title`, `key`,
    /// `command`) are always emitted, plus `order:` — it's the field that makes the list editable by
    /// hand, so it's always there to edit. An optional field is omitted when it equals the parser's
    /// default (shared via `ToolFloatParser`, so the two halves can't drift), keeping a plain float's
    /// line lean. `id` is never written: it's `slug(title)`, and storing it would be storing a
    /// restatement of the title that could drift from it. A value with whitespace or a `#` is quoted —
    /// the same rule `WorkspacesWriter` uses — so the parser's comment strip and whitespace tokenizer
    /// don't split it.
    static func serializeFloat(_ float: ToolFloat) -> String {
        var tokens = [
            "order:\(float.order)", "title:\(quotedValue(float.title))",
            "key:\(float.toggle.configToken)",
        ]
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
        if !float.showsInToolbar { tokens.append("toolbar:false") }
        return "float = " + tokens.joined(separator: " ")
    }

    /// Persist `floats` in the order given, stamping `order:` across all of them, 1…N. Stamping every
    /// float (not just the ones that moved) is what lets a config with no `order:` fields at all — the
    /// only kind that existed before ZEN-81 — become a full contiguous sequence on the first reorder,
    /// instead of a mix where some floats sort by an explicit number and the rest by line position.
    ///
    /// No line moves: every id is unchanged, so each float's line is rewritten where it already sits
    /// and only its number changes. That's the whole reason order is a field rather than line order —
    /// the file stays yours, comments and all.
    static func applyFloatOrder(_ floats: [ToolFloat], configRoot: URL = ConfigLoader.defaultRoot) throws {
        let resequenced = floats.enumerated().map { index, float -> ToolFloat in
            var float = float
            float.order = index + 1
            return float
        }
        try apply(floatUpserts: resequenced, configRoot: configRoot)
    }

    /// Replace each upsert's `float =` line in place (matched by id, preserving any trailing comment),
    /// or insert it into the slot a removal just vacated, else after the last existing float line, else
    /// append. Removals run first, dropping every float line whose id is in the set. Only float lines
    /// are touched; comments, blanks, and every other key survive verbatim.
    ///
    /// The vacated slot is what makes **rename** keep its place. A rename arrives as remove(old) +
    /// upsert(new) in one call, and since the new id was never in the file there's no line to replace —
    /// so it would otherwise land at the end of the block. That silently moves the float: on reload,
    /// floats with no `order:` of their own take their order from line position, so the ones that were
    /// below it inherit the slot it left and it slides down the dock (ZEN-81).
    private static func applyFloats(upserts: [ToolFloat], removals: Set<String>, in lines: inout [String]) {
        var vacated: Int?
        if !removals.isEmpty {
            vacated = lines.firstIndex { floatID(of: $0).map(removals.contains) ?? false }
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
            } else if let slot = vacated, slot <= lines.count {
                lines.insert(rendered, at: slot)
                vacated = nil  // one rename, one slot — a second new float goes to the end as usual
            } else if let lastFloat = lines.lastIndex(where: { floatID(of: $0) != nil }) {
                lines.insert(rendered, at: lastFloat + 1)  // group with the existing float lines
            } else {
                lines.append(rendered)
            }
        }
    }

    /// The id of an active `float =` line, else nil (not a float line, or it carries no usable title).
    /// Resolves through `ToolFloatParser.identity` — the same tokenizer *and* the same title→slug rule
    /// `parse` uses — so the writer can never disagree with the parser about which float a line is.
    private static func floatID(of line: String) -> String? {
        guard activeAssignmentKey(line) == "float", let equals = line.firstIndex(of: "=") else { return nil }
        let value = ConfigText.stripComment(String(line[line.index(after: equals)...]))
        return ToolFloatParser.identity(fields: ToolFloatParser.fields(value))
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
