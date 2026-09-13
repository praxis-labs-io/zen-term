/// `KeyInterceptor.resolve` consumes keymap chords before the picker check, so ⌥⏎ would never reach a TUI.
enum PickerChordGuard {
    static func shouldPassThrough(action: KeyInterceptor.ReservedChord, repoPickerIsOpen: Bool)
        -> Bool
    {
        switch action {
        case .createWorktree, .removeWorktree: return !repoPickerIsOpen
        default: return false
        }
    }
}
