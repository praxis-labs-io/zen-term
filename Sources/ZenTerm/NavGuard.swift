enum NavGuard {
    /// An open float passes Ctrl-nav through regardless of vim: pane nav is swallowed while a modal float is up.
    static func shouldPassThrough(
        chord: Chord, action: KeyInterceptor.ReservedChord, focusedPaneIsVim: Bool,
        toolFloatIsOpen: Bool
    ) -> Bool {
        guard (focusedPaneIsVim || toolFloatIsOpen), chord.control, !chord.command else { return false }
        switch action {
        case .navLeft, .navRight, .navUp, .navDown: return true
        default: return false
        }
    }
}
