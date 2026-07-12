import AppKit

/// The shared 2D keyboard-focus mechanics for the modal cards (`AddWorkspaceOverlay`,
/// `SettingsOverlay`). Each card supplies its own vertical stop list — the rows differ — but
/// the first-responder check and the clamp/step math are identical, so they live here.
enum KeyboardFocus {
    /// The keys a focus stop responds to, decoded from a raw `keyDown` event so the macOS
    /// keyCode constants live in exactly one place. Every focus stop (`SettingsNavRow`,
    /// `AppButton`, `SegmentedControl`, `KeybindChip`, `Dropdown`) maps the keys it cares
    /// about to its own action and lets the rest fall through — but they all agree on what
    /// each physical key *is*, so a keyCode fix or a new key lands once instead of drifting
    /// across five hand-maintained switch statements.
    enum Key: Equatable {
        case up
        case down
        case left
        case right
        case tab(shift: Bool)
        case activate  // Return, keypad Enter, or Space
        case delete  // Backspace or Forward-Delete
        case escape
    }

    /// Decode a `keyDown` event into the focus key it represents, or nil when it isn't one of
    /// them (the caller forwards it to `super.keyDown`, or consumes it — an open dropdown does).
    static func key(for event: NSEvent) -> Key? {
        switch event.keyCode {
        case 126: return .up
        case 125: return .down
        case 123: return .left
        case 124: return .right
        case 48: return .tab(shift: event.modifierFlags.contains(.shift))
        case 36, 76, 49: return .activate
        case 51, 117: return .delete
        case 53: return .escape
        default: return nil
        }
    }

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
