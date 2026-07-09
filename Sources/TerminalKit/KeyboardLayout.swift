import Carbon

/// The current keyboard input-source id (e.g. `com.apple.keylayout.US`).
///
/// `GhosttyHostView.keyDown` snaps this before and after handing a key to the input
/// system: if it changed while we weren't composing, an input method claimed the key and
/// it must not also reach the terminal. Minimal port of ghostty's own `KeyboardLayout`.
enum KeyboardLayout {
    static var id: String? {
        guard
            let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
            let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID)
        else { return nil }
        // TIS hands back an unmanaged raw pointer to a CFString property; bit-casting it is
        // the documented (Carbon) way to read it.
        return unsafeBitCast(pointer, to: CFString.self) as String
    }
}
