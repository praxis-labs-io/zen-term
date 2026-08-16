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
        /// `wide` is vim's WORD: whitespace-delimited, so `foo.bar` is one rather than three.
        case word(ScrollWordMotion.Motion, wide: Bool, times: Int)
        case lineStart
        case lineEnd
        /// `^`: the first cell on the row holding anything but whitespace.
        case firstNonBlank
        /// `H`/`M`/`L`: a row named by where it sits on screen rather than by a delta.
        case viewportRow(ViewportPlace, offset: Int)
        /// `*`: hand the word under the cursor to the find bar.
        case searchWordUnderCursor
        /// `yy`: copy whole rows without opening a selection first.
        case yankRow(times: Int)
        /// `f`/`F`/`t`/`T`: find a character along this row.
        case find(Find, times: Int)
        /// `;` and `,`: run the last find again, forward or the other way.
        case repeatFind(reversed: Bool, times: Int)
        /// First key of `yy`, when there is no selection for a bare `y` to take.
        case pendingYank
        /// `f`/`F`/`t`/`T` before its character has been typed.
        case pendingFind(Find.Target)
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

    /// Where on screen a row sits, for the motions that name one that way.
    enum ViewportPlace: Equatable { case top, middle, bottom }

    /// A character search along the cursor's own row. A word never spans a row break here, and
    /// neither does this.
    struct Find: Equatable {
        enum Direction: Equatable { case forward, backward }
        var direction: Direction
        /// `t`/`T` stop one cell short of the character rather than on it.
        var till: Bool
        var character: Character

        /// The same find the other way, which is what `,` runs.
        var reversed: Find {
            Find(
                direction: direction == .forward ? .backward : .forward, till: till,
                character: character)
        }

        /// An `f`/`F`/`t`/`T` that has not been given its character yet.
        struct Target: Equatable {
            var direction: Direction
            var till: Bool

            func find(_ character: Character) -> Find {
                Find(direction: direction, till: till, character: character)
            }
        }
    }

    /// A decoded keystroke: something to run, or a digit joining the count being typed. A digit is
    /// not a move, so it is not a `Command`.
    enum Key: Equatable {
        case run(Command)
        case count(Int)
    }

    /// What earlier keystrokes are still waiting on, threaded in by the caller so the decode stays
    /// a function of its arguments rather than of the mode's state.
    struct Pending: Equatable {
        /// Whether a `g` is armed, so a second one tops out.
        var afterG = false
        /// Whether a `y` is armed and a second one takes the row.
        var afterY = false
        /// An `f`/`F`/`t`/`T` waiting for the character to find.
        var awaitingFind: Find.Target?
        /// The count typed so far, or nil for none. `12j` is twelve rows.
        var count: Int?

        /// How far a command repeats. One when no count was typed, so every caller multiplies.
        var times: Int { max(count ?? 1, 1) }

        /// Four digits is past any viewport, and it bounds the loops a count drives.
        static let maximumCount = 9999

        /// Fold a digit in, or drop it once the count is already absurd.
        mutating func append(digit: Int) {
            let next = (count ?? 0) * 10 + digit
            count = min(next, Self.maximumCount)
        }
    }

    /// Decode a `keyDown`, or nil for a key the mode does not map. Shiftedness comes from the
    /// modifier flags, never the character's case: Caps Lock would make `g` top out and `j` dead.
    static func key(for event: NSEvent, pending: Pending, hasSelection: Bool = false)
        -> Key?
    {
        let held = event.modifierFlags.intersection([.command, .shift, .option, .control])
        // ⌃d/⌃u/⌃f/⌃b are the vim half- and full-page keys. Match Control exactly so ⌘⌃d and
        // friends fall through to whoever owns them.
        if held == .control {
            // A count multiplies the page rather than repeating it: libghostty takes the fraction
            // as a float, so `3⌃d` is one scroll of one and a half pages.
            let pages = Double(pending.times)
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "d": return .run(.scroll(.pageFraction(0.5 * pages)))
            case "u": return .run(.scroll(.pageFraction(-0.5 * pages)))
            case "f": return .run(.scroll(.pageFraction(pages)))
            case "b": return .run(.scroll(.pageFraction(-pages)))
            default: return nil
            }
        }
        // Everything else is bare or shifted. ⌘ and ⌥ belong to another handler.
        guard held.isSubset(of: .shift) else { return nil }
        if event.keyCode == escapeKeyCode {
            // An Esc waiting on a find character cancels that, not the mode: nil is consumed by the
            // caller, which drops everything armed.
            return pending.awaitingFind == nil ? .run(.cancel) : nil
        }
        // A find takes whatever character comes next, `j` and `0` included, so it runs first.
        if let target = pending.awaitingFind {
            guard let character = event.characters?.first else { return nil }
            return .run(.find(target.find(character), times: pending.times))
        }
        // Matched on the typed character, the only form that arrives: `charactersIgnoringModifiers`
        // applies Shift, so a US shift+[ reports "{" in both fields.
        let times = pending.times
        switch event.characters {
        case "{": return .run(.paragraph(-times))
        case "}": return .run(.paragraph(times))
        case "$": return .run(.lineEnd)
        case "^": return .run(.firstNonBlank)
        case "*": return .run(.searchWordUnderCursor)
        default: break
        }
        let shift = held.contains(.shift)
        switch (event.charactersIgnoringModifiers?.lowercased() ?? "", shift) {
        case ("j", false), (downArrow, false): return .run(.step(times))
        case ("k", false), (upArrow, false): return .run(.step(-times))
        case ("h", false), (leftArrow, false): return .run(.column(-times))
        case ("l", false), (rightArrow, false): return .run(.column(times))
        case ("w", false): return .run(.word(.next, wide: false, times: times))
        case ("b", false): return .run(.word(.back, wide: false, times: times))
        case ("e", false): return .run(.word(.end, wide: false, times: times))
        case ("w", true): return .run(.word(.next, wide: true, times: times))
        case ("b", true): return .run(.word(.back, wide: true, times: times))
        case ("e", true): return .run(.word(.end, wide: true, times: times))
        // `3H` is the third row down, so the count is an offset from the edge it names. `M` has
        // only one middle, and ignores it.
        case ("h", true): return .run(.viewportRow(.top, offset: times - 1))
        case ("m", true): return .run(.viewportRow(.middle, offset: 0))
        case ("l", true): return .run(.viewportRow(.bottom, offset: times - 1))
        // Vim's own rule: `0` is a motion until a count is being typed, and a digit after that.
        case ("0", false): return pending.count == nil ? .run(.lineStart) : .count(0)
        case ("1"..."9", false): return digit(event).map(Key.count)
        case ("v", false): return .run(.visual(.character))
        case ("v", true): return .run(.visual(.line))
        // `y` takes a selection when there is one, the way vim's visual mode does, and otherwise
        // waits for the second `y` that names whole rows.
        case ("y", false) where hasSelection: return .run(.yank)
        case ("y", false) where pending.afterY: return .run(.yankRow(times: times))
        case ("y", false): return .run(.pendingYank)
        case (" ", false): return .run(.scroll(.pageFraction(Double(times))))
        case ("g", false): return .run(pending.afterG ? .scroll(.top) : .pendingTop)
        case ("g", true): return .run(.scroll(.bottom))
        case ("f", false): return .run(.pendingFind(.init(direction: .forward, till: false)))
        case ("f", true): return .run(.pendingFind(.init(direction: .backward, till: false)))
        case ("t", false): return .run(.pendingFind(.init(direction: .forward, till: true)))
        case ("t", true): return .run(.pendingFind(.init(direction: .backward, till: true)))
        case (";", false): return .run(.repeatFind(reversed: false, times: times))
        case (",", false): return .run(.repeatFind(reversed: true, times: times))
        case ("q", false), ("i", false): return .run(.exit)
        default: return nil
        }
    }

    private static func digit(_ event: NSEvent) -> Int? {
        event.charactersIgnoringModifiers.flatMap(Int.init)
    }

    private static let escapeKeyCode: UInt16 = 53
    /// Arrow keys arrive as private-use scalars in `charactersIgnoringModifiers`, matched here so
    /// they work without a second keyCode branch.
    private static let upArrow = String(UnicodeScalar(NSUpArrowFunctionKey)!)
    private static let downArrow = String(UnicodeScalar(NSDownArrowFunctionKey)!)
    private static let leftArrow = String(UnicodeScalar(NSLeftArrowFunctionKey)!)
    private static let rightArrow = String(UnicodeScalar(NSRightArrowFunctionKey)!)
}
