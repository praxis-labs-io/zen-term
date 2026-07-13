/// The pass-through predicate for the nvim navigator: whether a keymap-bound chord should
/// reach the terminal (so nvim moves its own splits) instead of firing ZenTerm pane nav.
///
/// Pure and standalone so the truth table is unit-testable without an event loop.
/// `AppDelegate` supplies the live `focusedPaneIsVim`.
enum NavGuard {
    /// Pass through only `Ctrl`-nav (never `⌘`-nav) over a pane running nvim — so the
    /// default `⌘-hjkl` nav is untouched whether or not the focused pane is nvim, and a
    /// non-nav chord (or any chord over a non-nvim pane) is never diverted.
    static func shouldPassThrough(
        chord: Chord, action: KeyInterceptor.ReservedChord, focusedPaneIsVim: Bool
    ) -> Bool {
        guard focusedPaneIsVim, chord.control, !chord.command else { return false }
        switch action {
        case .navLeft, .navRight, .navUp, .navDown: return true
        default: return false
        }
    }
}
