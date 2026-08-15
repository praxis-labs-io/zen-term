import AppKit
import TerminalKit

/// Scroll mode's keyboard, decoded from an `NSEvent` and nothing else. Pure and static so the
/// keymap is testable without a window, the same seam `DiffPaneTable.vimKey(for:)` uses.
enum ScrollKeymap {
    /// One move through the buffer. Separate from `TerminalScroll` so the exits and the two-key
    /// prefixes, neither of which is a scroll, live in the same decode.
    enum Command: Equatable {
        case scroll(TerminalScroll)
        /// A one-line step, moving the cursor rather than the viewport until it is pinned at an
        /// edge. Apart from `.scroll(.lines(±1))` because that is a cursor versus a scrollbar.
        case step(Int)
        /// Vim's paragraph motion: the next blank row in this direction.
        case paragraph(Int)
        /// One cell left or right.
        case column(Int)
        case word(ScrollWordMotion.Motion)
        case lineStart
        case lineEnd
        /// `v` or `V`: open a selection here, swap its kind, or close the one that is up.
        case visual(ScrollSelection.Kind)
        case yank
        /// First `g` of `gg`. Arms the prefix; a second `g` tops out.
        case pendingTop
        /// Esc: hand back the selection if there is one, else leave the mode.
        case cancel
        /// `q` or `i`: leave outright, selection or no selection.
        case exit
    }

    /// What earlier keystrokes are still waiting on, threaded in by the caller so the decode stays
    /// a function of its arguments rather than of the mode's state.
    struct Pending: Equatable {
        /// Whether a `g` is armed, so a second one tops out.
        var afterG = false
    }

    /// Decode a `keyDown`, or nil for a key the mode does not map. Shiftedness comes from the
    /// modifier flags, never the character's case: Caps Lock would make `g` top out and `j` dead.
    static func command(for event: NSEvent, pending: Pending) -> Command? {
        let held = event.modifierFlags.intersection([.command, .shift, .option, .control])
        // ⌃d/⌃u/⌃f/⌃b are the vim half- and full-page keys. Match Control exactly so ⌘⌃d and
        // friends fall through to whoever owns them.
        if held == .control {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "d": return .scroll(.pageFraction(0.5))
            case "u": return .scroll(.pageFraction(-0.5))
            case "f": return .scroll(.pageFraction(1))
            case "b": return .scroll(.pageFraction(-1))
            default: return nil
            }
        }
        // Everything else is bare or shifted. ⌘ and ⌥ belong to another handler.
        guard held.isSubset(of: .shift) else { return nil }
        if event.keyCode == escapeKeyCode { return .cancel }
        // Matched on the typed character, the only form that arrives: `charactersIgnoringModifiers`
        // applies Shift, so a US shift+[ reports "{" in both fields.
        switch event.characters {
        case "{": return .paragraph(-1)
        case "}": return .paragraph(1)
        case "$": return .lineEnd
        default: break
        }
        let shift = held.contains(.shift)
        switch (event.charactersIgnoringModifiers?.lowercased() ?? "", shift) {
        case ("j", false), (downArrow, false): return .step(1)
        case ("k", false), (upArrow, false): return .step(-1)
        case ("h", false), (leftArrow, false): return .column(-1)
        case ("l", false), (rightArrow, false): return .column(1)
        case ("w", false): return .word(.next)
        case ("b", false): return .word(.back)
        case ("e", false): return .word(.end)
        case ("0", false): return .lineStart
        case ("v", false): return .visual(.character)
        case ("v", true): return .visual(.line)
        case ("y", false): return .yank
        case (" ", false): return .scroll(.pageFraction(1))
        case ("g", false): return pending.afterG ? .scroll(.top) : .pendingTop
        case ("g", true): return .scroll(.bottom)
        case ("q", false), ("i", false): return .exit
        default: return nil
        }
    }

    private static let escapeKeyCode: UInt16 = 53
    /// Arrow keys arrive as private-use scalars in `charactersIgnoringModifiers`, matched here so
    /// they work without a second keyCode branch.
    private static let upArrow = String(UnicodeScalar(NSUpArrowFunctionKey)!)
    private static let downArrow = String(UnicodeScalar(NSDownArrowFunctionKey)!)
    private static let leftArrow = String(UnicodeScalar(NSLeftArrowFunctionKey)!)
    private static let rightArrow = String(UnicodeScalar(NSRightArrowFunctionKey)!)
}
