import AppKit
import Carbon.HIToolbox

/// What the user's actual keyboard can type.
///
/// `Chord`'s shifted-glyph fold table is US-only, which is fine for *matching* (a config spec and a
/// live event pass through the same table), but not for judging whether a spec is reachable at all.
/// `keybind = split_vertical=cmd+|` is dead on a US layout — no key produces `|` without Shift — yet
/// perfectly typeable on a layout where `|` is unshifted. Guessing from the glyph would either miss
/// the dead bind or slander a working one, so ask the layout.
enum KeyboardLayout {
    /// Stubs the layout so tests don't depend on whatever keyboard the machine happens to have.
    /// DEBUG-only, mirroring `ConfigLoader.defaultRootOverrideForTesting`.
    #if DEBUG
        static var producibleGlyphsOverrideForTesting: ((Bool) -> Set<String>)?
    #endif

    /// Whether some keypress on the current layout can produce `chord`.
    ///
    /// **Main-thread-only, and this is where that constraint actually comes from:**
    /// `producibleGlyphs` calls `TISCopyCurrentKeyboardLayoutInputSource`, which off-main takes the
    /// whole process down with no crash report (ZEN-17). Everything above this — `KeymapAssembler`,
    /// `GeneralConfigParser`, `ConfigLoader` — is main-thread-only because it reaches here.
    ///
    /// Only Shift matters: `charactersIgnoringModifiers` — the reading `Chord(event:)` is built on —
    /// applies Shift and ignores ⌘/⌥/⌃, so those never change which glyph arrives.
    @MainActor
    static func canType(_ chord: Chord) -> Bool {
        guard !Chord.isSpecialKeyGlyph(chord.key) else { return true }  // arrows/return come from the keyCode
        // Canonicalize each producible glyph the same way a live event would be, then look for this
        // chord's key among the results — so the check can't drift from the fold it's checking.
        return producibleGlyphs(shift: chord.shift)
            .contains { Chord(shift: chord.shift, key: $0).key == chord.key }
    }

    /// Every single-character glyph the current layout produces, at the given Shift state.
    @MainActor
    private static func producibleGlyphs(shift: Bool) -> Set<String> {
        #if DEBUG
            if let override = producibleGlyphsOverrideForTesting { return override(shift) }
        #endif
        // The compile-time guard has one hole it structurally cannot close: a closure formed in a
        // main-actor context and handed to `DispatchQueue.async(execute:)` as a `DispatchWorkItem`
        // is type-erased at construction, so the compiler sees nothing crossing and the whole
        // isolated chain runs off-main anyway (measured, ZEN-31). Everything below this line is the
        // Carbon call that cannot survive that, and its native failure mode is exit 6 with no crash
        // report and nothing on stderr. Trap instead, so the violation names itself.
        MainActor.preconditionIsolated("KeyboardLayout: TIS is main-thread-only in a GUI app")
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
            let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else {
            return []
        }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        return data.withUnsafeBytes { buffer -> Set<String> in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return [] }
            // UCKeyTranslate wants the modifier byte from the old Carbon event record, not NSEvent's.
            let modifiers = shift ? UInt32((shiftKey >> 8) & 0xFF) : 0
            var glyphs: Set<String> = []
            for keyCode in UInt16(0)..<128 {
                var deadKeyState: UInt32 = 0  // reset per key: a dead key must not colour the next one
                var characters = [UniChar](repeating: 0, count: 4)
                var length = 0
                let status = UCKeyTranslate(
                    layout, keyCode, UInt16(kUCKeyActionDown), modifiers, UInt32(LMGetKbdType()),
                    UInt32(kUCKeyTranslateNoDeadKeysBit), &deadKeyState, characters.count, &length, &characters)
                guard status == noErr, length == 1 else { continue }
                let glyph = String(utf16CodeUnits: characters, count: length).lowercased()
                if glyph.count == 1 { glyphs.insert(glyph) }
            }
            return glyphs
        }
    }
}
