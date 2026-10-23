import AppKit
import Carbon.HIToolbox

/// Asks the live layout whether a chord is typeable, which `Chord`'s US-only fold table cannot answer.
enum KeyboardLayout {
    #if DEBUG
        static var layoutOverrideForTesting: ((Bool) -> [UInt16: String])?
    #endif

    @MainActor
    static func canType(_ chord: Chord) -> Bool { keyCode(for: chord) != nil }

    @MainActor
    static func keyCode(for chord: Chord) -> UInt16? { resolve(chord)?.keyCode }

    @MainActor
    static func resolve(_ chord: Chord) -> (keyCode: UInt16, unshiftedCodepoint: UInt32, text: String?)? {
        if let special = Chord.keyCodeForSpecialGlyph(chord.key) {
            return (special, 0, nil)
        }
        let typed = glyphsByKeyCode(shift: chord.shift)
            .filter { Chord(shift: chord.shift, key: $0.value).key == chord.key }
        guard let keyCode = typed.keys.min() else { return nil }
        guard chord.shift else {
            return (keyCode, typed[keyCode]?.unicodeScalars.first?.value ?? 0, nil)
        }
        let bare = glyphsByKeyCode(shift: false)[keyCode]?.unicodeScalars.first?.value ?? 0
        return (keyCode, bare, typed[keyCode])
    }

    /// Main-thread only: TIS called off-main kills the process with no crash report.
    @MainActor
    private static func glyphsByKeyCode(shift: Bool) -> [UInt16: String] {
        rawGlyphsByKeyCode(shift: shift).filter { _, glyph in
            guard let scalar = glyph.unicodeScalars.first else { return false }
            return scalar.value >= 0x20 && scalar.value != 0x7F
        }
    }

    @MainActor
    private static func rawGlyphsByKeyCode(shift: Bool) -> [UInt16: String] {
        #if DEBUG
            if let override = layoutOverrideForTesting { return override(shift) }
        #endif
        MainActor.preconditionIsolated("KeyboardLayout: TIS is main-thread-only in a GUI app")
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
            let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else {
            return [:]
        }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        return data.withUnsafeBytes { buffer -> [UInt16: String] in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return [:] }
            let modifiers = shift ? UInt32((shiftKey >> 8) & 0xFF) : 0
            var glyphs: [UInt16: String] = [:]
            for keyCode in UInt16(0)..<128 {
                var deadKeyState: UInt32 = 0
                var characters = [UniChar](repeating: 0, count: 4)
                var length = 0
                let status = UCKeyTranslate(
                    layout, keyCode, UInt16(kUCKeyActionDown), modifiers, UInt32(LMGetKbdType()),
                    UInt32(kUCKeyTranslateNoDeadKeysBit), &deadKeyState, characters.count, &length, &characters)
                guard status == noErr, length == 1 else { continue }
                let glyph = String(utf16CodeUnits: characters, count: length).lowercased()
                if glyph.count == 1 { glyphs[keyCode] = glyph }
            }
            return glyphs
        }
    }
}
