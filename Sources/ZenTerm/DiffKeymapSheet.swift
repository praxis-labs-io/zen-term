import AppKit

/// The diff viewer's full key reference, built as content for a `ChromePopover` (opened with bare `?`). Three
/// grouped columns of compact keycap + label rows — Tree, Diff, General — so the footer legend can stay
/// lean and this carries the rest. A pure builder: it reads `Theme.current` at build time, so the popover
/// re-creates it on a live theme change.
enum DiffKeymapSheet {
    /// The chord a keymap action holds right now, for the rows that quote one.
    ///
    /// Read live rather than written out: focus tree/diff answers the `nav_left` / `nav_right`
    /// **actions**, so it follows the keymap and follows a user's rebind, and a hand-written glyph
    /// here drifts the moment either moves. It has drifted before. An unbound action prints nothing
    /// rather than a chord that does nothing.
    private static func glyph(_ action: KeyInterceptor.ReservedChord) -> [String] {
        Chord.displayed(action, in: GeneralConfig.current.keymap).map { [$0.displayGlyph] } ?? []
    }

    private static var groups: [(title: String, rows: [(keys: [String], label: String)])] {
        [
            (
                "Tree",
                [
                    (["j", "k"], "Prev / next file"),
                    (["h", "l"], "Fold / open file"),
                    (["⌃j", "⌃k"], "Page files"),
                    (["⌃d", "⌃u"], "Scroll diff"),
                    (["b"], "Base branch"),
                ]
            ),
            (
                "Diff",
                [
                    (["j", "k"], "Move cursor"),
                    (["{", "}"], "Prev / next change"),
                    (["gg", "G"], "Top / bottom"),
                    (["0", "$"], "Line start / end"),
                    (["⌃d", "⌃u"], "Half page"),
                    (["V"], "Select lines"),
                    (["y", "Y"], "Yank code / ref"),
                    (["⏎"], "Comment"),
                ]
            ),
            (
                "General",
                [
                    (glyph(.navLeft) + glyph(.navRight), "Focus tree / diff"),
                    (["\\"], "Toggle layout"),
                    (["q", "esc"], "Close"),
                    (["?"], "This sheet"),
                ]
            ),
        ]
    }

    static func makeContent() -> NSView {
        let columns = NSStackView(views: groups.map { column($0.title, $0.rows) })
        columns.orientation = .horizontal
        columns.alignment = .top
        columns.spacing = 22
        return columns
    }

    private static func column(_ title: String, _ rows: [(keys: [String], label: String)]) -> NSView {
        let header = NSTextField(labelWithString: title.uppercased())
        header.font = .systemFont(ofSize: 9, weight: .semibold)
        header.textColor = Theme.current.chrome.ink(alpha: 0.4)
        let stack = NSStackView(views: [header] + rows.map { row($0.keys, $0.label) })
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7
        stack.setCustomSpacing(9, after: header)  // a wider gap under the group title
        return stack
    }

    private static func row(_ keys: [String], _ label: String) -> NSView {
        // Hug tightly so a row wider than its content (rows share the column's width) grows the trailing
        // label's frame, never a stretched keycap — otherwise the first cap absorbs the slack and reads wide.
        let caps: [NSView] = keys.map { key -> NSView in
            let cap = KeycapView(shortcut: key, size: .compact)
            cap.setContentHuggingPriority(.required, for: .horizontal)
            cap.setContentCompressionResistancePriority(.required, for: .horizontal)
            return cap
        }
        let text = NSTextField(labelWithString: label)
        text.font = .systemFont(ofSize: 11)
        text.textColor = Theme.current.chrome.foreground.nsColor
        let stack = NSStackView(views: caps + [text])
        stack.orientation = .horizontal
        stack.spacing = 3  // tight between the keycaps
        stack.alignment = .centerY
        if let lastCap = caps.last { stack.setCustomSpacing(7, after: lastCap) }  // wider before the label
        return stack
    }
}
