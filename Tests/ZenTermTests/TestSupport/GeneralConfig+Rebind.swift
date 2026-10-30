@testable import ZenTerm

extension GeneralConfig {
    mutating func rebind(_ action: KeyInterceptor.ReservedChord, to chord: Chord) {
        keymap = keymap.filter { $0.value != action }
        keymap[chord] = action
    }
}
