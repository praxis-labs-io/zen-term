import AppKit

/// The pass-through predicate for a text view holding the keyboard: whether a keymap-bound chord
/// belongs to the box you are typing in rather than to ZenTerm.
///
/// `KeyInterceptor` is an event monitor that resolves the keymap **ahead of the responder chain**,
/// so a reserved chord never reaches the focused control. That is right for ⌘T and wrong for the
/// ⌘⇧ arrows: `NSTextView` binds those itself, to extend-selection-to-start and to-end-of-document,
/// and binding the prompt jumps on them took that away from the Report an Issue composer. Over a
/// modal card it is worse than a no-op, because `WindowController.handle` swallows an unrecognised
/// chord in silence.
///
/// **Membership is measured, not assumed.** ⌘A looks like it belongs here and does not: AppKit
/// serves Select All from the Edit menu, not from `NSTextView`, so a pass-through would defer the
/// chord to nobody. It is served by the menu item instead, which reaches a field and a pane both,
/// and the keymap ships no default on it. Sending the keystroke to a real text view and
/// reading its selection back is the only way to tell the two cases apart.
///
/// Pure and standalone for the reason `NavGuard` is, and a sibling to it rather than a branch
/// inside it: the two answer different questions and share only the seam they return through.
/// `AppDelegate` supplies the live first responder.
enum TextEditingChords {
    /// Keyed on the **chord**, not the action. The question is whether the box holding the keyboard
    /// already does something with this keystroke, which is a fact about the keys rather than about
    /// whatever ZenTerm happens to have bound to them. Move the prompt jumps elsewhere and these go
    /// back to being the text view's alone, which is the right answer both ways round.
    ///
    /// Only the chords a ZenTerm default can actually claim. ⌘← and ⌘⌫ are text editing's too and
    /// are deliberately absent: no default binds them, so they never reach a guard, and listing
    /// them here would suggest this set is the whole of what macOS owns.
    ///
    /// The Return pair is here for a different reason from the arrows. AppKit turns every Return
    /// into `insertNewline(_:)` whatever modifiers ride along, so a composer reading them off the
    /// raw event needs them intact. Fill Screen is ⌘⏎ and Focus Mode ⌘⇧⏎, which is right for a
    /// window and wrong for a caret.
    private static let owned: Set<Chord> = [
        Chord(command: true, shift: true, key: "↑"),
        Chord(command: true, shift: true, key: "↓"),
        Chord(command: true, key: "⏎"),
        Chord(command: true, shift: true, key: "⏎"),
    ]

    /// A focused `NSTextField` makes the window's **field editor** first responder, which is an
    /// `NSTextView`, so this one check covers both a single-line field and a real text view.
    static func owns(_ chord: Chord, firstResponder: NSResponder?) -> Bool {
        guard firstResponder is NSTextView else { return false }
        return owned.contains(chord)
    }
}
