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

    /// `fallbackOrder` is the float's line order in the file, used when the line has no `order:` —
    /// so a config that has never been reordered reads exactly as it did before `order:` existed.
    static func parse(_ value: String, fallbackOrder: Int = 0) -> ToolFloat? {
        let fields = fields(value)

        let title = fields["title"] ?? ""
        guard let id = identity(fields: fields) else {
            Log.warning(
                "GeneralConfig: float line needs a `title:` with at least one letter or number — ignored",
                category: .toolFloat)
            return nil
        }
        guard let command = fields["command"], !command.isEmpty else {
            Log.warning(
                "GeneralConfig: float `\(id)` missing required `command:` — ignored", category: .toolFloat)
            return nil
        }
        guard let keySpec = fields["key"], let toggle = Chord.parse(keySpec) else {
            Log.warning(
                "GeneralConfig: float `\(id)` has a missing or unparseable `key:` — ignored",
                category: .toolFloat)
            return nil
        }

        let persist = persistence(fields["persist"], id: id)
        return ToolFloat(
            id: id,
            order: fields["order"].flatMap { Int($0) } ?? fallbackOrder,
            title: title,
            icon: fields["icon"] ?? Self.defaultIcon,
            command: command,
            dir: fields["dir"].flatMap(Self.resolveDir),
            widthFraction: fraction(fields["width"]) ?? Self.defaultFraction,
            heightFraction: fraction(fields["height"]) ?? Self.defaultFraction,
            requiresGitRepo: fields["git"]?.lowercased() == "true",
            persist: persist,
            toggle: toggle)
    }

    /// A width/height fraction clamped to a sane 0.2…1.0 — an unclamped 0 collapses the float
    /// (invalid Auto Layout multiplier) and a value > 1 overflows the window.
    private static func fraction(_ raw: String?) -> CGFloat? {
        guard let value = raw.flatMap({ Double($0) }), value.isFinite else { return nil }
        return clampedFraction(value)
    }

    /// A float's `persist:` value. An unrecognized token warns and falls back to the default rather
    /// than dropping the float — an ephemeral float still works, so a typo shouldn't cost the tool.
    private static func persistence(_ raw: String?, id: String) -> ToolFloat.Persistence {
        guard let raw else { return defaultPersist }
        guard let value = ToolFloat.Persistence(rawValue: raw.lowercased()) else {
            Log.warning(
                "GeneralConfig: float `\(id)` has unknown `persist:\(raw)` — using `none`", category: .toolFloat)
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
