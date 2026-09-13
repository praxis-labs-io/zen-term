import AppKit
import TerminalKit

// Takes a value, not an `NSEvent`: the pin-bump baseline asks about a chord nobody pressed.
extension TerminalKey {
    @MainActor
    init?(chord: Chord) {
        guard let key = KeyboardLayout.resolve(chord) else { return nil }
        var modifiers: NSEvent.ModifierFlags = []
        if chord.command { modifiers.insert(.command) }
        if chord.shift { modifiers.insert(.shift) }
        if chord.option { modifiers.insert(.option) }
        if chord.control { modifiers.insert(.control) }
        self.init(
            keyCode: key.keyCode, modifiers: modifiers,
            unshiftedCodepoint: key.unshiftedCodepoint, text: key.text)
    }
}
