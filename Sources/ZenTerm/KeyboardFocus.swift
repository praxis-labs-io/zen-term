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

    /// The modifiers a shortcut can be built from. The rest of `modifierFlags` is incidental to the
    /// physical key, so a comparison has to mask down to these before asking which modifier was held.
    private static let reservableModifiers: NSEvent.ModifierFlags = [.command, .shift, .option, .control]

    /// Whether Option, and only Option, was held — the reorder modifier on a list row, where ⌥↑
    /// has to mean "move this" while a bare ↑ still means "move focus".
    ///
    /// Masking with `reservableModifiers` rather than `deviceIndependentFlagsMask` is the whole
    /// point: AppKit tags every arrow event with `.function` and `.numericPad`, which
    /// `deviceIndependentFlagsMask` keeps, so that comparison never equals a bare `.option` and the
    /// reorder is dead in the app while a synthesized test event passes (ZEN-81). Requiring Option
    /// to be the only reservable modifier still keeps ⌥⌘↑ out.
    static func isOptionOnly(_ event: NSEvent) -> Bool {
        event.modifierFlags.intersection(reservableModifiers) == .option
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

    /// The next index when stepping `delta` from `from` within `count` stops (nil = no move). With
    /// no anchor (`from == nil`), a forward step lands on the first stop and a backward step on the
    /// last.
    ///
    /// `wrap` decides the ends: arrows clamp (holding Down at the last row shouldn't teleport to the
    /// top), while Tab wraps — a Tab loop that stops dead at the last stop reads as broken.
    static func step(from: Int?, delta: Int, count: Int, wrap: Bool = false) -> Int? {
        guard count > 0 else { return nil }
        guard let from else { return delta > 0 ? 0 : count - 1 }
        let next = from + delta
        if (0..<count).contains(next) { return next }
        guard wrap else { return nil }
        return ((next % count) + count) % count  // Swift's % keeps the sign; normalize to 0..<count
    }

    /// Scroll `stop` into its scroll view, along with the strip above it that belongs to it: the group
    /// caption or section header between it and the previous stop, or the document's top inset when
    /// nothing above is a stop. Revealing the stop alone parks that strip just off the top edge, so
    /// arrowing up into a group hides the header naming it, and the strip is why this needs the stop
    /// list rather than the one view.
    ///
    /// AppKit doesn't scroll to a newly-focused responder on its own. `stops` is the section's or
    /// list's ordered stops; `stop` need not be one of them (a stop's whole row is passed where the
    /// row carries an inline message that should come along).
    ///
    /// One position, computed and applied once. Revealing the strip and then the stop with two
    /// `scrollToVisible` calls reaches the same place in two hops, and padding a single rect on both
    /// sides makes the far edge pull the near one around.
    static func reveal(_ stop: NSView, among stops: [NSView]) {
        guard let scroll = stop.enclosingScrollView, let document = scroll.documentView else { return }
        // Frames are the geometry this reads, and a list that just reloaded its rows has stale ones.
        document.layoutSubtreeIfNeeded()
        let viewport = scroll.contentView.bounds.height
        let frame = stop.convert(stop.bounds, to: document)
        let padded = frame.insetBy(dx: 0, dy: -12)  // shared breathing room above and below a stop
        let previousBottom =
            stops
            .map { $0.convert($0.bounds, to: document).maxY }
            .filter { $0 <= frame.minY }
            .max() ?? document.bounds.minY

        // Aim past the edge the stop arrives at rather than flush against it: a row landing hard against
        // the pane edge arrives with no context around it, and walking the list reads as scraping the
        // bottom. On the arriving edge only — padding both sides moves the list while the stop is still
        // mid-pane. Capped against a short pane, where a third of the clip is plenty.
        let margin = min(84, viewport / 3)
        let revealTop = min(previousBottom, padded.minY)
        var top = scroll.contentView.bounds.minY
        if padded.maxY + margin > top + viewport { top = padded.maxY + margin - viewport }  // down
        if revealTop - margin < top { top = revealTop - margin }  // up: the strip comes with the stop
        if padded.maxY > top + viewport { top = padded.maxY - viewport }  // the stop outranks the strip
        let clamped = min(max(0, top), max(0, document.frame.height - viewport))
        // Snapped to the backing store's pixel grid: `margin` is a third of the clip on a short pane, and
        // a fractional offset leaves every glyph in the pane drawn between two device pixels.
        let scale = scroll.window?.backingScaleFactor ?? 2
        scroll.contentView.scroll(
            to: NSPoint(x: scroll.contentView.bounds.minX, y: (clamped * scale).rounded() / scale))
        scroll.reflectScrolledClipView(scroll.contentView)
    }
}
