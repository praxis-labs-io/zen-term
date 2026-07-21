import AppLog
import CoreGraphics
import Foundation

/// Parses a single `float =` value into a `ToolFloat`. Grammar: whitespace-separated
/// `field:value` tokens, quote-aware so a command may contain spaces
/// (`command:"npm run dev"`). Each token splits on its FIRST `:`. Best-effort: a line
/// missing a required field (`title`, `key`, `command`) or with an unparseable `key:` is
/// dropped with a warning; optional fields fall back to sensible defaults.
enum ToolFloatParser {
    /// The defaults an omitted optional field falls back to — shared with `ConfigWriter`, which omits
    /// a field from its serialized line when the value equals the default, so the two halves can't drift.
    static let defaultIcon = "square.on.square"
    static let defaultFraction: CGFloat = 0.85
    static let defaultPersist: ToolFloat.Persistence = .ephemeral

    /// The valid width/height range, plus the shared clamp + compact format — one home for the
    /// fraction grammar so the parser, the `float =` writer, and the Settings form can't disagree on
    /// the range or how a fraction reads (`0.85`, not `0.850000`).
    static let fractionRange: ClosedRange<CGFloat> = 0.2...1.0
    static func clampedFraction(_ value: Double) -> CGFloat {
        CGFloat(min(max(value, Double(fractionRange.lowerBound)), Double(fractionRange.upperBound)))
    }
    static func fractionText(_ value: CGFloat) -> String { String(format: "%g", Double(value)) }

    /// A float's stable id, derived from its title: lowercased, with every run of non-alphanumerics
    /// collapsed to a single `-` and the ends trimmed ("Open GitDash" → "open-gitdash"). Unicode-aware
    /// (`isLetter` / `isNumber`), so a non-ASCII title slugs to itself rather than to nothing. Empty
    /// only when the title holds no letters or numbers at all (an emoji-only title) — callers reject
    /// that rather than mint an unaddressable float.
    static func slug(forTitle title: String) -> String {
        var slug = ""
        var pendingSeparator = false
        for character in title.lowercased() {
            guard character.isLetter || character.isNumber else {
                pendingSeparator = true
                continue
            }
            if pendingSeparator, !slug.isEmpty { slug.append("-") }  // never leads with a `-`
            pendingSeparator = false
            slug.append(character)
        }
        return slug
    }

    /// The id a parsed `float =` line resolves to, else nil when it carries no usable title. `parse`
    /// and `ConfigWriter`'s line matching both go through this, so the writer can never disagree with
    /// the parser about which float a line *is* — the one invariant the whole scheme rests on.
    static func identity(fields: [String: String]) -> String? {
        let id = slug(forTitle: fields["title"] ?? "")
        return id.isEmpty ? nil : id
    }

    /// Split a `float =` value into its `field:value` map — quote-aware, each token split on its
    /// first `:`, values unquoted. The read half of the grammar `ConfigWriter.serializeFloat` writes;
    /// `ConfigWriter` also uses it to read a line's `title:` when matching a float to replace/remove.
    static func fields(_ value: String) -> [String: String] {
        var fields: [String: String] = [:]
        for token in tokenize(value) {
            guard let colon = token.firstIndex(of: ":") else { continue }
            let field = String(token[..<colon])
            let raw = String(token[token.index(after: colon)...])
            fields[field] = ConfigText.unquote(raw)
        }
        return fields
    }

    /// The float a `float =` line resolves to, or nil when it was dropped. The convenience over
    /// `parseLine` for callers (and round-trip tests) that only care about the float, not why a line
    /// was ignored.
    static func parse(_ value: String, fallbackOrder: Int = 0) -> ToolFloat? {
        parseLine(value, fallbackOrder: fallbackOrder).float
    }

    /// Parse a `float =` line into its float and every `ConfigDiagnostic` the line raised (ZEN-7). A
    /// dropped line returns no float and one diagnostic saying why. A line that *makes* a float can
    /// still raise diagnostics for an optional sub-field that fell back (`order:`/`persist:`/`width:`/
    /// `height:`) — the float works, but the file didn't get what it asked for, and that must not be
    /// silent. A dropped line's diagnostic has no row (Tools notice + toast); a surviving float's
    /// renders on its Tools row.
    /// `fallbackOrder` is the float's line order in the file, used when the line has no `order:` — so
    /// a config that has never been reordered reads exactly as it did before `order:` existed.
    static func parseLine(
        _ value: String, fallbackOrder: Int = 0
    ) -> (float: ToolFloat?, diagnostics: [ConfigDiagnostic]) {
        let fields = fields(value)

        let title = fields["title"] ?? ""
        guard let id = identity(fields: fields) else {
            Log.warning(
                "GeneralConfig: float line needs a `title:` with at least one letter or number — ignored",
                category: .toolFloat)
            return (nil, [dropped("a float line", .floatMissingField("title:"))])
        }
        guard let command = fields["command"], !command.isEmpty else {
            Log.warning(
                "GeneralConfig: float `\(id)` missing required `command:` — ignored", category: .toolFloat)
            return (nil, [dropped(title, .floatMissingField("command:"))])
        }
        guard let keySpec = fields["key"], !keySpec.isEmpty else {
            // An empty `key:` is missing, not unusable — reporting it as an unusable key would name a
            // blank chord and read as a keyboard limitation. Mirrors the `!command.isEmpty` guard above.
            Log.warning(
                "GeneralConfig: float `\(id)` missing required `key:` — ignored", category: .toolFloat)
            return (nil, [dropped(title, .floatMissingField("key:"))])
        }
        guard let toggle = Chord.parse(keySpec) else {
            Log.warning(
                "GeneralConfig: float `\(id)` has an unparseable `key:\(keySpec)` — ignored",
                category: .toolFloat)
            return (nil, [dropped(title, .floatUnusableKey(keySpec))])
        }

        // The required fields are good, so this makes a float. Optional sub-fields fall back on a bad
        // value, but each collects a diagnostic (and a log) so the fallback isn't silent.
        var diagnostics: [ConfigDiagnostic] = []
        let float = ToolFloat(
            id: id,
            order: order(fields["order"], fallback: fallbackOrder, id: id, label: title, &diagnostics),
            title: title,
            icon: fields["icon"] ?? Self.defaultIcon,
            command: command,
            dir: fields["dir"].flatMap(Self.resolveDir),
            widthFraction: fraction(fields["width"], field: "width:", id: id, label: title, &diagnostics),
            heightFraction: fraction(fields["height"], field: "height:", id: id, label: title, &diagnostics),
            requiresGitRepo: fields["git"]?.lowercased() == "true",
            persist: persistence(fields["persist"], id: id, label: title, &diagnostics),
            toggle: toggle)
        return (float, diagnostics)
    }

    /// A dropped-float diagnostic labelled by the line's title (or a generic stand-in when the title
    /// is what's missing) — the label is what the Tools notice and toast name the ignored line by.
    private static func dropped(_ label: String, _ problem: ConfigDiagnostic.Problem) -> ConfigDiagnostic {
        ConfigDiagnostic(scope: .toolFloat(label: label), problem: problem)
    }

    /// A surviving float's sub-field diagnostic, keyed by `id` (matches its Tools row) and labelled by
    /// `label` (names it in the toast, where there's no row).
    private static func fieldInvalid(
        _ id: String, _ label: String, _ field: String, got: String, using: String
    ) -> ConfigDiagnostic {
        ConfigDiagnostic(
            scope: .toolFloatField(id: id, label: label),
            problem: .floatFieldInvalid(field: field, got: got, using: using))
    }
    private static func fieldClamped(
        _ id: String, _ label: String, _ field: String, got: String, to: String
    ) -> ConfigDiagnostic {
        ConfigDiagnostic(
            scope: .toolFloatField(id: id, label: label),
            problem: .floatFieldClamped(field: field, got: got, to: to))
    }

    /// A float's `order:`, or the file-line position when absent (valid by design) or non-integer
    /// (a fallback that used to be fully silent — now logged and surfaced).
    private static func order(
        _ raw: String?, fallback: Int, id: String, label: String, _ diags: inout [ConfigDiagnostic]
    ) -> Int {
        guard let raw else { return fallback }
        guard let value = Int(raw) else {
            Log.warning(
                "GeneralConfig: float `\(id)` has a non-integer `order:\(raw)` — using file order",
                category: .toolFloat)
            diags.append(fieldInvalid(id, label, "order:", got: raw, using: "file order"))
            return fallback
        }
        return value
    }

    /// A width/height fraction clamped to a sane 0.2…1.0 — an unclamped 0 collapses the float
    /// (invalid Auto Layout multiplier) and a value > 1 overflows the window. An omitted value takes
    /// the default silently; a bad or out-of-range one falls back the same way but is surfaced.
    private static func fraction(
        _ raw: String?, field: String, id: String, label: String, _ diags: inout [ConfigDiagnostic]
    ) -> CGFloat {
        guard let raw else { return defaultFraction }
        guard let value = Double(raw), value.isFinite else {
            Log.warning(
                "GeneralConfig: float `\(id)` has an unparseable `\(field)\(raw)` — using "
                    + "\(fractionText(defaultFraction))", category: .toolFloat)
            diags.append(fieldInvalid(id, label, field, got: raw, using: fractionText(defaultFraction)))
            return defaultFraction
        }
        let clamped = clampedFraction(value)
        if clamped != CGFloat(value) {
            Log.warning(
                "GeneralConfig: float `\(id)` `\(field)\(raw)` out of range "
                    + "\(fractionText(fractionRange.lowerBound))…\(fractionText(fractionRange.upperBound)) — "
                    + "clamped to \(fractionText(clamped))", category: .toolFloat)
            diags.append(fieldClamped(id, label, field, got: raw, to: fractionText(clamped)))
        }
        return clamped
    }

    /// A float's `persist:` value. An unrecognized token warns and falls back to the default rather
    /// than dropping the float — an ephemeral float still works, so a typo shouldn't cost the tool.
    private static func persistence(
        _ raw: String?, id: String, label: String, _ diags: inout [ConfigDiagnostic]
    ) -> ToolFloat.Persistence {
        guard let raw else { return defaultPersist }
        guard let value = ToolFloat.Persistence(rawValue: raw.lowercased()) else {
            Log.warning(
                "GeneralConfig: float `\(id)` has unknown `persist:\(raw)` — using `none`", category: .toolFloat)
            diags.append(fieldInvalid(id, label, "persist:", got: raw, using: "none"))
            return defaultPersist
        }
        return value
    }

    /// One home for the `dir:` grammar: tilde-expand + standardize raw text into the URL form
    /// `ToolFloat.dir` stores. Shared by the parser and the Settings form (the same rule as the
    /// fraction helpers above) so the same text can't resolve two different ways — a drift would
    /// mean a dir that validates in Settings anchors somewhere else after a config reload. With
    /// `persist:dir` a pinned directory makes the anchor constant, so the instance never re-anchors
    /// — the intended way to keep a tool alive at a fixed place.
    static func resolveDir(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return URL(fileURLWithPath: NSString(string: trimmed).expandingTildeInPath).standardizedFileURL
    }

    /// Split on whitespace, but keep runs inside double quotes intact so a quoted value can
    /// carry spaces. The quotes themselves are preserved here and stripped per-value later.
    private static func tokenize(_ value: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuotes = false
        for character in value {
            if character == "\"" {
                inQuotes.toggle()
                current.append(character)
            } else if character.isWhitespace, !inQuotes {
                if !current.isEmpty { tokens.append(current); current = "" }
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }
}
