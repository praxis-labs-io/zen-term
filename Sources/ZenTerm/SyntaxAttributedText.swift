import AppKit

/// Builds a diff line as an `NSAttributedString` for the syntax-highlighted path: a `base`
/// foreground over the whole line, each span's range overridden with its role color resolved from the
/// live theme. Colors resolve here, at render time, from the passed `chrome` — the row model carries
/// only roles, so a theme swap recolors on the next `configure`. Shared by the split
/// (`DiffLineCell`) and inline (`UnifiedLineCell`) renderers. Only used when spans are present; a line
/// with no spans keeps the flat `stringValue`/`textColor` path.
enum SyntaxAttributedText {
    /// Diff lines never wrap — they pan inside a clip, so the tail is revealed by scrolling.
    /// `DiffCellMetrics.contentLabel()` sets `lineBreakMode = .byClipping` on the *label*, which governs
    /// `stringValue`; an attributed string instead carries its own paragraph style, and with none set it
    /// inherits the default — `.byWordWrapping`. Combined with `maximumNumberOfLines = 1` that renders
    /// only the first wrapped line, silently dropping whole words off the end of a line the moment the
    /// frame is a hair short. Carrying the label's clipping mode here is what keeps the attributed path
    /// behaving like the plain one.
    private static let clipping: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byClipping
        return style
    }()

    static func make(
        _ text: String, spans: [TokenSpan], base: NSColor, font: NSFont, chrome: ChromeTheme
    ) -> NSAttributedString {
        let attributed = NSMutableAttributedString(
            string: text, attributes: [.foregroundColor: base, .font: font, .paragraphStyle: clipping])
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
