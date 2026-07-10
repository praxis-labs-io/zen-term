import CoreGraphics
import TerminalKit

/// Parses a ghostty-format theme (`key = value` lines) into a `TerminalTheme`. Best-effort:
/// any missing, malformed, or unknown key keeps the corresponding `fallback` value, so a
/// partial or extra-laden file (even a full ghostty config) still yields a usable theme.
/// Font is injected by the caller — ghostty *themes* carry no font. The inverse of
/// `GhosttyConfigWriter.configText`.
enum GhosttyThemeParser {
    static func parse(
        _ text: String, fontName: String, fontSize: CGFloat, fallback: TerminalTheme
    ) -> TerminalTheme {
        var background = fallback.background
        var foreground = fallback.foreground
        var cursor = fallback.cursor
        var selectionBackground = fallback.selectionBackground
        var ansi = fallback.ansi

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let equals = line.firstIndex(of: "=") else {
                continue
            }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "background": if let color = TerminalColor(hex: value) { background = color }
            case "foreground": if let color = TerminalColor(hex: value) { foreground = color }
            case "cursor-color": if let color = TerminalColor(hex: value) { cursor = color }
            case "selection-background":
                if let color = TerminalColor(hex: value) { selectionBackground = color }
            case "palette":
                // value form: "N=#rrggbb"
                guard let separator = value.firstIndex(of: "="),
                    let index = Int(value[..<separator].trimmingCharacters(in: .whitespaces)),
                    ansi.indices.contains(index),
                    let color = TerminalColor(
                        hex: value[value.index(after: separator)...].trimmingCharacters(in: .whitespaces))
                else { continue }
                ansi[index] = color
            default:
                continue
            }
        }

        return TerminalTheme(
            fontName: fontName, fontSize: fontSize,
            background: background, foreground: foreground,
            cursor: cursor, selectionBackground: selectionBackground, ansi: ansi)
    }
}
