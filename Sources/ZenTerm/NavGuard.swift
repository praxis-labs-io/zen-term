/// The pass-through predicate for the nvim navigator: whether a keymap-bound chord should
/// reach the terminal (so nvim moves its own splits) instead of firing ZenTerm pane nav.
///
/// Pure and standalone so the truth table is unit-testable without an event loop.
/// `AppDelegate` supplies the live `focusedPaneIsVim` and `toolFloatIsOpen`.
enum NavGuard {
    /// Pass through only `Ctrl`-nav, never `⌘`-nav — so the default `⌘-hjkl` nav is untouched
    /// in every case, and a non-nav chord is never diverted. Two things claim a `Ctrl`-nav
    /// chord ahead of pane nav:
    ///
    /// - **A pane running nvim**, so it moves its own splits and hands off at its edge over the
    ///   nav socket. This is the seamless-nav opt-in.
    /// - **An open tool float** (ZEN-270), whatever it is running. A float is modal, so
    ///   `WindowController.handle` swallows nav while one is up — consuming the chord takes it
    ///   from the tool and then drops it, which is how `Ctrl-hjkl` died inside an nvim float.
    ///   There is no vim check here because there is nothing to weigh it against: the chord has
    ///   no ZenTerm meaning over a float either way.
    static func shouldPassThrough(
        chord: Chord, action: KeyInterceptor.ReservedChord, focusedPaneIsVim: Bool,
        toolFloatIsOpen: Bool
    ) -> Bool {
        guard focusedPaneIsVim || toolFloatIsOpen, chord.control, !chord.command else { return false }
        switch action {
        case .navLeft, .navRight, .navUp, .navDown: return true
        default: return false
        }
    }
}
