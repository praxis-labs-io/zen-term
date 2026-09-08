/// `KeyInterceptor.resolve` consumes any chord in the keymap before the picker check runs, so
/// without this ⌥⏎ is dead everywhere, including where a TUI needs it to insert a newline.
enum PickerChordGuard {
    static func shouldPassThrough(action: KeyInterceptor.ReservedChord, repoPickerIsOpen: Bool)
        -> Bool
    {
        switch action {
        case .createWorktree: return !repoPickerIsOpen
        default: return false
        }
    }
}
