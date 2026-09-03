/// The pass-through predicate for the two chords that only mean anything over the workspace
/// picker: whether one should reach the terminal instead of being consumed.
///
/// `KeyInterceptor.resolve` consumes every chord in the keymap, and the picker check in
/// `WindowController.handle` runs *after* that — too late for the program in the pane. Without
/// this the chords are dead keys everywhere, and both are keys a terminal must not eat:
/// `⌥⌫` is delete-previous-word in every readline shell, and `⌥⏎` inserts a newline without
/// submitting in Claude Code and other TUIs.
///
/// Pure and standalone so the truth table is unit-testable without an event loop, mirroring
/// `NavGuard`. `AppDelegate` supplies the live `repoPickerIsOpen`.
enum PickerChordGuard {
    static func shouldPassThrough(
        action: KeyInterceptor.ReservedChord, repoPickerIsOpen: Bool
    ) -> Bool {
        switch action {
        case .cloneWorkspace, .removeClone: return !repoPickerIsOpen
        default: return false
        }
    }
}
