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
    static let defaultPersist: ToolFloat.Persistence = .ephemeral
    static func defaultTitle(forID id: String) -> String { "Open \(id)" }

    /// The valid width/height range, plus the shared clamp + compact format — one home for the
    /// fraction grammar so the parser, the `float =` writer, and the Settings form can't disagree on
    /// the range or how a fraction reads (`0.85`, not `0.850000`).
    static let fractionRange: ClosedRange<CGFloat> = 0.2...1.0
    static func clampedFraction(_ value: Double) -> CGFloat {
        CGFloat(min(max(value, Double(fractionRange.lowerBound)), Double(fractionRange.upperBound)))
    }
    static func fractionText(_ value: CGFloat) -> String { String(format: "%g", Double(value)) }

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

        let persist = persistence(fields["persist"], id: id)
        return ToolFloat(
            id: id,
            title: fields["title"] ?? Self.defaultTitle(forID: id),
            icon: fields["icon"] ?? Self.defaultIcon,
            command: command,
            dir: directory(fields["dir"], id: id),
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
            NSLog("GeneralConfig: float `\(id)` has unknown `persist:\(raw)` — using `none`")
            return defaultPersist
        }
        return value
    }

    /// A float's pinned `dir:`, tilde-expanded. With `persist:dir` a pinned directory makes the
    /// anchor constant, so the instance simply never re-anchors — the intended way to keep a tool
    /// alive at a fixed place.
    private static func directory(_ raw: String?, id: String) -> URL? {
        guard let raw, !raw.isEmpty else { return nil }
        return URL(fileURLWithPath: NSString(string: raw).expandingTildeInPath).standardizedFileURL
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
