import AppKit
import TerminalKit

/// How the chrome asks a backend what it would do with a keystroke.
///
/// This is why the seam takes a value rather than an `NSEvent`: the caller has no event. The
/// pin-bump baseline asks about a chord nobody pressed, and reaches the backend through the
/// layout instead.
extension TerminalKey {
    /// Nil when no key on the current layout types this chord, which is the same answer
    /// `KeyboardLayout.canType` gives and for the same reason: a chord that cannot be typed here
    /// cannot be handed to a backend as a keystroke either.
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
