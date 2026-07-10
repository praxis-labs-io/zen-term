import AppKit

/// The shared 2D keyboard-focus mechanics for the modal cards (`AddWorkspaceOverlay`,
/// `SettingsOverlay`). Each card supplies its own vertical stop list — the rows differ — but
/// the first-responder check and the clamp/step math are identical, so they live here.
enum KeyboardFocus {
    /// Whether `view` currently holds first responder, resolving a text field's field editor
    /// (the actual responder while editing) back to the field itself.
    static func isFocused(_ view: NSView, in window: NSWindow?) -> Bool {
        guard let responder = window?.firstResponder else { return false }
        if let editor = responder as? NSTextView, let field = editor.delegate as? NSTextField {
            return field === view
        }
        return responder === view
    }

    /// The next index when stepping `delta` from `from` within `count` stops, clamped at the
    /// ends (nil = no move). With no anchor (`from == nil`), a forward step lands on the first
    /// stop and a backward step on the last.
    static func step(from: Int?, delta: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let from else { return delta > 0 ? 0 : count - 1 }
        let next = from + delta
        return (0..<count).contains(next) ? next : nil
    }
}
