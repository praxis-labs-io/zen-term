import AppKit
import GhosttyKit

/// The `NSView` libghostty renders into and that forwards input to a `GhosttySurface`'s
/// surface. libghostty attaches its own Metal layer to this view (making
/// it layer-hosting), so this view must NOT set `wantsLayer` itself. Coordinates handed
/// to libghostty use a top-left origin, so mouse `y` is flipped from AppKit's.
final class GhosttyHostView: NSView {
    weak var owner: GhosttySurface?
    var surfacePtr: ghostty_surface_t?

    private var trackingArea: NSTrackingArea?

    // MARK: IME / dead-key composition state

    /// The whole preedit (marked) text — what the input method is still composing, shown
    /// underlined at the cursor. libghostty tracks no internal caret sub-range, so this
    /// attributed string is the entire model. Read by the `NSTextInputClient` conformance
    /// in GhosttyHostViewIME.swift.
    var markedText = NSMutableAttributedString()

    /// Non-nil only for the duration of a `keyDown`: it flags `insertText`/`setMarkedText`
    /// that they are being driven by `interpretKeyEvents` (queue the text) rather than by a
    /// standalone event like dictation or the character palette (commit it immediately).
    var keyTextAccumulator: [String]?

    override var acceptsFirstResponder: Bool { true }

    // MARK: Size / scale

    /// Push the current backing size and content scale into libghostty. Called on every
    /// geometry or backing-store change; libghostty tolerates a zero size until the first
    /// real layout.
    func syncSizeAndScale() {
        guard let surfacePtr else { return }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        ghostty_surface_set_content_scale(surfacePtr, scale, scale)
        // Skip zero sizes: the view has no bounds until the chrome lays it out, and
        // pushing 0×0 would collapse libghostty's sensible default grid to nothing.
        let backing = convertToBacking(bounds).size
        guard backing.width >= 1, backing.height >= 1 else { return }
        ghostty_surface_set_size(surfacePtr, UInt32(backing.width), UInt32(backing.height))
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        syncSizeAndScale()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        syncSizeAndScale()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        syncSizeAndScale()
    }

    override func updateTrackingAreas() {
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    // MARK: Focus

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if let surfacePtr { ghostty_surface_set_focus(surfacePtr, true) }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if let surfacePtr { ghostty_surface_set_focus(surfacePtr, false) }
        return ok
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        guard let surfacePtr else { return }
        // Shift+Enter → LF so multiline-aware CLIs treat it as a soft newline while
        // plain Enter (CR) still submits — the convention `claude /terminal-setup`
        // writes, and what the SwiftTerm backend implements. keyCode 36 = kVK_Return.
        // MUST stay ahead of the interpretKeyEvents hand-off so the IME can't swallow it.
        // Guarded on not-composing: mid-preedit, Enter must reach the input system to
        // commit the composition, not shortcut out and strand a stale underline.
        if markedText.length == 0, event.isSoftNewline {
            ghostty_surface_text(surfacePtr, "\n", 1)
            return
        }

        // Ask libghostty which modifiers it consumed for text translation (handles configs
        // like option-as-alt), then apply ONLY those four named flags on top of the event's
        // own modifierFlags. Deriving the whole set from the ghostty bitmask instead would
        // drop capsLock and the hidden device/keypad bits AppKit carries — bits that matter
        // for dead keys, and whose loss forces an identity-breaking event rebuild that
        // breaks CJK composition (AppKit's input system keys off NSEvent object identity).
        let translated = NSEvent.eventModifierFlags(
            mods: ghostty_surface_key_translation_mods(surfacePtr, event.ghosttyMods))
        var translationMods = event.modifierFlags
        for flag: NSEvent.ModifierFlags in [.shift, .control, .option, .command] {
            if translated.contains(flag) { translationMods.insert(flag) } else { translationMods.remove(flag) }
        }
        let translationEvent: NSEvent
        if translationMods == event.modifierFlags {
            translationEvent = event
        } else {
            translationEvent =
                NSEvent.keyEvent(
                    with: event.type, location: event.locationInWindow, modifierFlags: translationMods,
                    timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil,
                    characters: event.characters(byApplyingModifiers: translationMods) ?? "",
                    charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
                    isARepeat: event.isARepeat, keyCode: event.keyCode) ?? event
        }

        let action: ghostty_input_action_e = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS

        // Enter a keyDown scope: interpretKeyEvents will route composed text back through
        // insertText/setMarkedText, which accumulate into keyTextAccumulator instead of
        // committing directly. This is what lets multi-keystroke composition work.
        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }

        // Whether we were mid-composition before this event, and the keyboard layout going
        // in — a key that switches layout (some IMEs) shouldn't reach the terminal.
        let markedTextBefore = markedText.length > 0
        let keyboardIdBefore: String? = markedTextBefore ? nil : KeyboardLayout.id

        interpretKeyEvents([translationEvent])

        // If the layout changed and we weren't composing, an input method grabbed the key.
        if !markedTextBefore, keyboardIdBefore != KeyboardLayout.id { return }

        // Reflect the (possibly updated) preedit into libghostty, clearing it if a prior
        // composition just ended.
        syncPreedit(clearIfNeeded: markedTextBefore)

        if let accumulated = keyTextAccumulator, !accumulated.isEmpty {
            // Composition produced final text — send it as ordinary key input (never
            // "composing", since it's the committed result).
            for text in accumulated {
                _ = keyAction(action, event: event, translationEvent: translationEvent, text: text)
            }
        } else {
            // No composed text: an ordinary key. We ARE composing if a preedit is live, or
            // if one existed before this event — the latter catches a Backspace that only
            // cancels the composition and must NOT also delete a real char in the shell.
            _ = keyAction(
                action, event: event, translationEvent: translationEvent,
                text: translationEvent.ghosttyCharacters,
                composing: markedText.length > 0 || markedTextBefore)
        }
    }

    override func keyUp(with event: NSEvent) {
        // Swallow the release for the soft-newline chord we consumed in keyDown; a bare
        // RELEASE for a PRESS the terminal never saw confuses key-protocol-aware TUIs.
        if event.isSoftNewline { return }
        _ = keyAction(GHOSTTY_ACTION_RELEASE, event: event)
    }

    /// Encode one key event to libghostty. `translationEvent` carries the mod-translated
    /// event (for `consumed_mods`); `composing` marks input that is part of an in-flight
    /// IME composition so libghostty doesn't forward it to the shell. Returns whether
    /// libghostty consumed the event.
    @discardableResult
    func keyAction(
        _ action: ghostty_input_action_e, event: NSEvent,
        translationEvent: NSEvent? = nil, text: String? = nil, composing: Bool = false
    ) -> Bool {
        guard let surfacePtr else { return false }
        var key = event.ghosttyKeyEvent(action, translationMods: translationEvent?.modifierFlags)
        key.composing = composing
        // Encode UTF-8 text only for non-control input; libghostty encodes control
        // characters itself from the keycode + mods (so ctrl+key stays correct).
        if let text, let first = text.utf8.first, first >= 0x20 {
            return text.withCString {
                key.text = $0
                return ghostty_surface_key(surfacePtr, key)
            }
        }
        return ghostty_surface_key(surfacePtr, key)
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        owner?.reportFocusWanted()
        guard let surfacePtr else { return }
        _ = ghostty_surface_mouse_button(surfacePtr, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, event.ghosttyMods)
    }

    override func mouseUp(with event: NSEvent) {
        guard let surfacePtr else { return }
        _ = ghostty_surface_mouse_button(surfacePtr, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, event.ghosttyMods)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let surfacePtr else { return super.rightMouseDown(with: event) }
        _ = ghostty_surface_mouse_button(surfacePtr, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, event.ghosttyMods)
    }

    override func rightMouseUp(with event: NSEvent) {
        guard let surfacePtr else { return super.rightMouseUp(with: event) }
        _ = ghostty_surface_mouse_button(surfacePtr, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, event.ghosttyMods)
    }

    override func mouseMoved(with event: NSEvent) { reportMousePos(event) }
    override func mouseDragged(with event: NSEvent) { reportMousePos(event) }
    override func rightMouseDragged(with event: NSEvent) { reportMousePos(event) }

    override func mouseExited(with event: NSEvent) {
        guard let surfacePtr, NSEvent.pressedMouseButtons == 0 else { return }
        // Negative coordinates tell libghostty the cursor left the viewport.
        ghostty_surface_mouse_pos(surfacePtr, -1, -1, event.ghosttyMods)
    }

    private func reportMousePos(_ event: NSEvent) {
        guard let surfacePtr else { return }
        let pos = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surfacePtr, pos.x, frame.height - pos.y, event.ghosttyMods)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let surfacePtr else { return }
        var x = event.scrollingDeltaX
        var y = event.scrollingDeltaY
        let precise = event.hasPreciseScrollingDeltas
        if precise {
            x *= 2  // subjective feel multiplier, matching Ghostty's own app
            y *= 2
        }
        // Packed scroll mods: bit 0 = high-precision. Momentum phases are tracked in ZEN-68.
        let mods: ghostty_input_scroll_mods_t = precise ? 1 : 0
        ghostty_surface_mouse_scroll(surfacePtr, x, y, mods)
    }
}

extension NSEvent {
    /// The Shift+Enter soft-newline chord: Return (keyCode 36) with Shift and no other
    /// modifier. Requiring shift *exclusively* leaves Ctrl/Cmd/Opt+Shift+Enter to reach
    /// libghostty's key encoder as real chords (kitty-protocol CSI-u, ghostty binds)
    /// rather than collapsing them all to a bare LF.
    var isSoftNewline: Bool {
        guard keyCode == 36 else { return false }
        let active = modifierFlags.intersection([.shift, .control, .option, .command])
        return active == .shift
    }

    /// Ghostty modifier bitmask from this event's AppKit modifier flags.
    var ghosttyMods: ghostty_input_mods_e { Self.ghosttyMods(modifierFlags) }

    /// Ghostty modifier bitmask from an arbitrary AppKit modifier-flag set.
    static func ghosttyMods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var mods = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { mods |= GHOSTTY_MODS_CAPS.rawValue }
        return ghostty_input_mods_e(mods)
    }

    /// AppKit modifier flags back from a ghostty mods bitmask — the inverse of
    /// `ghosttyMods`, used to apply libghostty's translated mods to a rebuilt `NSEvent`.
    static func eventModifierFlags(mods: ghostty_input_mods_e) -> NSEvent.ModifierFlags {
        var flags = NSEvent.ModifierFlags(rawValue: 0)
        if mods.rawValue & GHOSTTY_MODS_SHIFT.rawValue != 0 { flags.insert(.shift) }
        if mods.rawValue & GHOSTTY_MODS_CTRL.rawValue != 0 { flags.insert(.control) }
        if mods.rawValue & GHOSTTY_MODS_ALT.rawValue != 0 { flags.insert(.option) }
        if mods.rawValue & GHOSTTY_MODS_SUPER.rawValue != 0 { flags.insert(.command) }
        return flags
    }

    /// A Ghostty key event carrying the physical keycode + mods; libghostty maps the
    /// keycode to its own key enum. Text is set separately by the caller. Ported from
    /// Ghostty's own `NSEvent.ghosttyKeyEvent`. `translationMods`, when given, is the
    /// mod-translated set libghostty used to produce text (option-as-alt etc.) and drives
    /// `consumed_mods` — otherwise the event's own mods are used.
    func ghosttyKeyEvent(
        _ action: ghostty_input_action_e, translationMods: NSEvent.ModifierFlags? = nil
    ) -> ghostty_input_key_s {
        var key = ghostty_input_key_s()
        key.action = action
        key.keycode = UInt32(keyCode)
        key.text = nil
        key.composing = false
        key.mods = ghosttyMods
        // Heuristic that has held for years in Ghostty: control and command never
        // contribute to text translation; everything else may.
        let consumed = (translationMods ?? modifierFlags).subtracting([.control, .command])
        key.consumed_mods = Self.ghosttyMods(consumed)
        key.unshifted_codepoint = 0
        if type == .keyDown || type == .keyUp,
            let scalar = characters(byApplyingModifiers: [])?.unicodeScalars.first
        {
            key.unshifted_codepoint = scalar.value
        }
        return key
    }

    /// The text to hand libghostty for a key event: the typed characters, minus control
    /// characters (libghostty encodes those itself) and PUA function-key codepoints.
    /// Ported from Ghostty's own `NSEvent.ghosttyCharacters`.
    var ghosttyCharacters: String? {
        guard let characters else { return nil }
        if characters.count == 1, let scalar = characters.unicodeScalars.first {
            if scalar.value < 0x20 {
                return self.characters(byApplyingModifiers: modifierFlags.subtracting(.control))
            }
            if scalar.value >= 0xF700 && scalar.value <= 0xF8FF { return nil }
        }
        return characters
    }
}
