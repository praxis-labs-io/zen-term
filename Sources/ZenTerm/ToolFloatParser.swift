import AppLog
import CoreGraphics
import Foundation

/// Grammar: whitespace-separated, quote-aware `field:value` tokens, each split on its first `:`.
enum ToolFloatParser {
    /// Defaults are shared with `ConfigWriter`, which omits a field equal to its default.
    static let defaultIcon = "square.on.square"
    static let defaultFraction: CGFloat = 0.85
    static let defaultPersist: ToolFloat.Persistence = .ephemeral

    static let fractionRange: ClosedRange<CGFloat> = 0.2...1.0
    static func clampedFraction(_ value: Double) -> CGFloat {
        CGFloat(min(max(value, Double(fractionRange.lowerBound)), Double(fractionRange.upperBound)))
    }
    static func fractionText(_ value: CGFloat) -> String { String(format: "%g", Double(value)) }

    static func slug(forTitle title: String) -> String {
        var slug = ""
        var pendingSeparator = false
        for character in title.lowercased() {
            guard character.isLetter || character.isNumber else {
                pendingSeparator = true
                continue
            }
            if pendingSeparator, !slug.isEmpty { slug.append("-") }
            pendingSeparator = false
            slug.append(character)
        }
        return slug
    }

    /// `ConfigWriter` matches lines through this, so it can never disagree with the parser on which float a line is.
    static func identity(fields: [String: String]) -> String? {
        let id = slug(forTitle: fields["title"] ?? "")
        return id.isEmpty ? nil : id
    }

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

    static func parse(_ value: String, fallbackOrder: Int = 0) -> ToolFloat? {
        parseLine(value, fallbackOrder: fallbackOrder).float
    }

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
            toggle: toggle,
            showsInToolbar: toolbarVisibility(fields["toolbar"], id: id, label: title, &diagnostics))
        return (float, diagnostics)
    }

    private static func dropped(_ label: String, _ problem: ConfigDiagnostic.Problem) -> ConfigDiagnostic {
        ConfigDiagnostic(scope: .toolFloat(label: label), problem: problem)
    }

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

    /// Unknown values keep the button shown: the default is true, so a typo must not hide it.
    private static func toolbarVisibility(
        _ raw: String?, id: String, label: String, _ diags: inout [ConfigDiagnostic]
    ) -> Bool {
        guard let raw else { return true }
        switch raw.lowercased() {
        case "true": return true
        case "false": return false
        default:
            Log.warning(
                "GeneralConfig: float `\(id)` has unknown `toolbar:\(raw)` — showing the button",
                category: .toolFloat)
            diags.append(fieldInvalid(id, label, "toolbar:", got: raw, using: "true"))
            return true
        }
    }

    static func resolveDir(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return URL(fileURLWithPath: PathDisplay.expandingHome(trimmed)).standardizedFileURL
    }

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
