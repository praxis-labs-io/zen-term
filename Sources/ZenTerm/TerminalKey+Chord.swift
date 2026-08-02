import AppKit
import TerminalKit

/// How the chrome asks a backend what it would do with a keystroke.
///
/// Two callers, and they are why the seam takes a value rather than an `NSEvent`. The live path
/// has a real event. The load-time diagnostic and the pin-bump baseline ask about a chord nobody
/// pressed, and reach the backend through the layout instead.
extension TerminalKey {
    init(event: NSEvent) {
        self.init(
            keyCode: event.keyCode,
            modifiers: event.modifierFlags,
            unshiftedCodepoint: event.charactersIgnoringModifiers?.unicodeScalars.first?.value ?? 0)
    }

    /// Nil when no key on the current layout types this chord, which is the same answer
    /// `KeyboardLayout.canType` gives and for the same reason: a chord that cannot be typed here
    /// cannot be handed to a backend as a keystroke either.
    @MainActor
    init?(chord: Chord) {
        guard let keyCode = KeyboardLayout.keyCode(for: chord) else { return nil }
        var modifiers: NSEvent.ModifierFlags = []
        if chord.command { modifiers.insert(.command) }
        if chord.shift { modifiers.insert(.shift) }
        if chord.option { modifiers.insert(.option) }
        if chord.control { modifiers.insert(.control) }
        self.init(
            keyCode: keyCode, modifiers: modifiers,
            unshiftedCodepoint: KeyboardLayout.unshiftedCodepoint(forKeyCode: keyCode))
    }
}
