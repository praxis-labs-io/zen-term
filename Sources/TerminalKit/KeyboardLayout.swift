import Carbon

/// The current keyboard input-source id (e.g. `com.apple.keylayout.US`).
///
/// `GhosttyHostView.keyDown` snaps this before and after handing a key to the input
/// system: if it changed while we weren't composing, an input method claimed the key and
/// it must not also reach the terminal. Minimal port of ghostty's own `KeyboardLayout`.
enum KeyboardLayout {
    /// Main-thread-only, like every TIS call in a GUI app: off-main it takes the whole process
    /// down with no crash report, nothing on stderr, and no stack to read, and `swift test` can't
    /// catch it because TIS answers happily in the xctest process. Both callers
    /// are `GhosttyHostView.keyDown`, so nothing violates this today — the annotation and the
    /// precondition are here because this is reachable from anywhere in the chrome and its native
    /// failure mode leaves no evidence to debug. See `docs/swift-conventions.md`, "Carbon and the
    /// main thread".
    @MainActor
    static var id: String? {
        MainActor.preconditionIsolated("KeyboardLayout: TIS is main-thread-only in a GUI app")
        guard
            let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
            let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID)
        else { return nil }
        // TIS hands back an unmanaged raw pointer to a CFString property; bit-casting it is
        // the documented (Carbon) way to read it.
        return unsafeBitCast(pointer, to: CFString.self) as String
    }
}
