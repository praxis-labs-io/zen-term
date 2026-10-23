/// `KeyInterceptor.resolve` consumes keymap chords before the picker check, so ⌥⏎ would never reach a TUI.
enum PickerChordGuard {
    static func shouldPassThrough(
        action: KeyInterceptor.ReservedChord, repoPickerIsOpen: Bool, sidebarHasFocus: Bool
    ) -> Bool {
        switch action {
        case .createWorktree: return !repoPickerIsOpen && !sidebarHasFocus
        case .removeWorktree: return !repoPickerIsOpen
        default: return false
        }
    }
}
