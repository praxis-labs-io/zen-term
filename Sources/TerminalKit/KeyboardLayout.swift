import Carbon

// The current input-source id, snapped around `keyDown` to detect an input method claiming a key.
enum KeyboardLayout {
    // TIS off the main thread kills the process with no crash report, and `swift test` cannot catch it.
    @MainActor
    static var id: String? {
        MainActor.preconditionIsolated("KeyboardLayout: TIS is main-thread-only in a GUI app")
        guard
            let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
            let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID)
        else { return nil }
        return unsafeBitCast(pointer, to: CFString.self) as String
    }
}
