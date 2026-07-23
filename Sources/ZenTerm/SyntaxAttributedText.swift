import AppKit

/// Builds a diff line as an `NSAttributedString` for the syntax-highlighted path (ZEN-238): a `base`
/// foreground over the whole line, each span's range overridden with its role color resolved from the
/// live theme. Colors resolve here, at render time, from the passed `chrome` — the row model carries
/// only roles, so a theme swap recolors on the next `configure` (ZEN-27). Shared by the split
/// (`DiffLineCell`) and inline (`UnifiedLineCell`) renderers. Only used when spans are present; a line
/// with no spans keeps the flat `stringValue`/`textColor` path.
enum SyntaxAttributedText {
    static func make(
        _ text: String, spans: [TokenSpan], base: NSColor, font: NSFont, chrome: ChromeTheme
    ) -> NSAttributedString {
        let attributed = NSMutableAttributedString(
            string: text, attributes: [.foregroundColor: base, .font: font])
        let full = NSRange(location: 0, length: attributed.length)
        for span in spans {
            // Clamp to the rendered text so a span computed against a different revision of the line
            // (a stale parse) can't index past its end and crash the render.
            guard let range = span.range.intersection(full), range.length > 0 else { continue }
            attributed.addAttribute(.foregroundColor, value: span.role.color(chrome), range: range)
        }
        return attributed
    }

    /// The whole-line color when a line isn't syntax-highlighted: added reads positive, removed
    /// destructive, context the plain foreground. Shared by both cell renderers' flat fallback.
    static func flatColor(for kind: DiffLineKind, chrome: ChromeTheme) -> NSColor {
        switch kind {
        case .added: return chrome.positive.nsColor
        case .removed: return chrome.destructive.nsColor
        case .context: return chrome.foreground.nsColor
        }
    }
}
