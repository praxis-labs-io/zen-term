import CoreGraphics
import Foundation

/// Parses a single `float =` value into a `ToolFloat`. Grammar: whitespace-separated
/// `field:value` tokens, quote-aware so a command may contain spaces
/// (`command:"npm run dev"`). Each token splits on its FIRST `:`. Best-effort: a line
/// missing a required field (`id`, `key`, `command`) or with an unparseable `key:` is
/// dropped with a warning; optional fields fall back to sensible defaults.
enum ToolFloatParser {
    static func parse(_ value: String) -> ToolFloat? {
        var fields: [String: String] = [:]
        for token in tokenize(value) {
            guard let colon = token.firstIndex(of: ":") else { continue }
            let field = String(token[..<colon])
            let raw = String(token[token.index(after: colon)...])
            fields[field] = unquote(raw)
        }

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
            title: fields["title"] ?? "Open \(id)",
            icon: fields["icon"] ?? "square.on.square",
            command: command,
            widthFraction: fields["width"].flatMap { Double($0) }.map { CGFloat($0) } ?? 0.85,
            heightFraction: fields["height"].flatMap { Double($0) }.map { CGFloat($0) } ?? 0.85,
            requiresGitRepo: fields["git"] == "true",
            emptyGuard: nil,
            toggle: toggle)
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

    /// Strip one surrounding pair of double quotes, if present.
    private static func unquote(_ value: String) -> String {
        guard value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") else { return value }
        return String(value.dropFirst().dropLast())
    }
}
