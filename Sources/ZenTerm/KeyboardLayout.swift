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
    /// DEBUG-only, mirroring `ConfigLoader.defaultRootOverrideForTesting`. Keyed by keyCode
    /// because the reverse lookup needs the physical key, not only the glyph.
    #if DEBUG
        static var layoutOverrideForTesting: ((Bool) -> [UInt16: String])?
    #endif

    /// Whether some keypress on the current layout can produce `chord`.
    ///
    /// **Main-thread-only, and this is where that constraint actually comes from:**
    /// `glyphsByKeyCode` calls `TISCopyCurrentKeyboardLayoutInputSource`, which off-main takes the
    /// whole process down with no crash report (ZEN-17). Everything above this — `KeymapAssembler`,
    /// `GeneralConfigParser`, `ConfigLoader` — is main-thread-only because it reaches here.
    ///
    /// Only Shift matters: `charactersIgnoringModifiers` — the reading `Chord(event:)` is built on —
    /// applies Shift and ignores ⌘/⌥/⌃, so those never change which glyph arrives.
    @MainActor
    static func canType(_ chord: Chord) -> Bool { keyCode(for: chord) != nil }

    /// The physical key that types `chord` on this layout, or nil when no key can.
    ///
    /// A keyCode is what a backend keymap matches on: asking one what it does with `cmd+k` means
    /// naming the key, not the letter. Special keys resolve straight from `Chord`'s own table,
    /// since they never appear in a character table.
    ///
    /// Returns the lowest matching keyCode. A layout can put one glyph on two keys (the numeric
    /// keypad), and a keymap bind written as a glyph means the main-row key.
    @MainActor
    static func keyCode(for chord: Chord) -> UInt16? { resolve(chord)?.keyCode }

    /// Everything a backend keymap needs in order to be asked about `chord`, or nil when no key on
    /// this layout types it.
    ///
    /// One entry point because the answers come from the same walk: splitting them made the
    /// unshifted case walk 128 keys through Carbon twice to answer one question. A shifted chord
    /// genuinely needs both states, because the bind may be written either way round, so it still walks
    /// twice, and only then.
    ///
    /// `text` is the glyph the keystroke types with Shift applied, and it is nil rather than the
    /// bare glyph for an unshifted chord: the two are the same character there, and sending it
    /// twice would tell a keymap the key was typed when the question is only what it is bound to.
    @MainActor
    static func resolve(_ chord: Chord) -> (keyCode: UInt16, unshiftedCodepoint: UInt32, text: String?)? {
        if let special = Chord.keyCodeForSpecialGlyph(chord.key) {
            // Arrows and Return type no character, so there is no glyph for a keymap to match on.
            return (special, 0, nil)
        }
        // Canonicalize each producible glyph the same way a live event would be, then look for this
        // chord's key among the results, so the lookup can't drift from the fold it's checking.
        let typed = glyphsByKeyCode(shift: chord.shift)
            .filter { Chord(shift: chord.shift, key: $0.value).key == chord.key }
        guard let keyCode = typed.keys.min() else { return nil }
        guard chord.shift else {
            return (keyCode, typed[keyCode]?.unicodeScalars.first?.value ?? 0, nil)
        }
        let bare = glyphsByKeyCode(shift: false)[keyCode]?.unicodeScalars.first?.value ?? 0
        return (keyCode, bare, typed[keyCode])
    }

    /// Each keyCode the current layout maps to a single typed character, at the given Shift state.
    /// The one walk behind every question here, so a lookup and its reverse cannot drift apart.
    ///
    /// Control characters are not typed characters and are excluded. `UCKeyTranslate` answers for
    /// the arrows and Return too (U+001C..U+001F and CR), all length 1, and letting those through
    /// would put a control codepoint where callers are promised the glyph a key types or nothing.
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
            return [:]
        }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        return data.withUnsafeBytes { buffer -> [UInt16: String] in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return [:] }
            // UCKeyTranslate wants the modifier byte from the old Carbon event record, not NSEvent's.
            let modifiers = shift ? UInt32((shiftKey >> 8) & 0xFF) : 0
            var glyphs: [UInt16: String] = [:]
            for keyCode in UInt16(0)..<128 {
                var deadKeyState: UInt32 = 0  // reset per key: a dead key must not colour the next one
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
