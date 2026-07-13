import CoreGraphics
import Foundation

/// Parses a single `float =` value into a `ToolFloat`. Grammar: whitespace-separated
/// `field:value` tokens, quote-aware so a command may contain spaces
/// (`command:"npm run dev"`). Each token splits on its FIRST `:`. Best-effort: a line
/// missing a required field (`id`, `key`, `command`) or with an unparseable `key:` is
/// dropped with a warning; optional fields fall back to sensible defaults.
enum ToolFloatParser {
    /// The defaults an omitted optional field falls back to — shared with `ConfigWriter`, which omits
    /// a field from its serialized line when the value equals the default, so the two halves can't drift.
    static let defaultIcon = "square.on.square"
    static let defaultFraction: CGFloat = 0.85
    static func defaultTitle(forID id: String) -> String { "Open \(id)" }

    /// Split a `float =` value into its `field:value` map — quote-aware, each token split on its
    /// first `:`, values unquoted. The read half of the grammar `ConfigWriter.serializeFloat` writes;
    /// `ConfigWriter` also uses it to read a line's `id:` when matching a float to replace/remove.
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

    static func parse(_ value: String) -> ToolFloat? {
        let fields = fields(value)

        guard let id = fields["id"], !id.isEmpty else {
            NSLog("GeneralConfig: float line missing required `id:` — ignored")
            return nil
        }
        guard let command = fields["command"], !command.isEmpty else {
            NSLog("GeneralConfig: float `\(id)` missing required `command:` — ignored")
            return nil
        }
        guard let keySpec = fields["key"], let toggle = Chord.parse(keySpec) else {
            NSLog("GeneralConfig: float `\(id)` has a missing or unparseable `key:` — ignored")
            return nil
        }

        return ToolFloat(
            id: id,
            title: fields["title"] ?? Self.defaultTitle(forID: id),
            icon: fields["icon"] ?? Self.defaultIcon,
            command: command,
            widthFraction: fraction(fields["width"]) ?? Self.defaultFraction,
            heightFraction: fraction(fields["height"]) ?? Self.defaultFraction,
            requiresGitRepo: fields["git"]?.lowercased() == "true",
            emptyGuard: nil,
            toggle: toggle)
    }

    /// A width/height fraction clamped to a sane 0.2…1.0 — an unclamped 0 collapses the float
    /// (invalid Auto Layout multiplier) and a value > 1 overflows the window.
    private static func fraction(_ raw: String?) -> CGFloat? {
        guard let value = raw.flatMap({ Double($0) }), value.isFinite else { return nil }
        return CGFloat(min(max(value, 0.2), 1.0))
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
