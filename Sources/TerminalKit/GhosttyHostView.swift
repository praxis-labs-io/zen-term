import AppKit
import GhosttyKit

/// The `NSView` libghostty renders into and that forwards input to a `GhosttySurface`'s
/// surface (ZEN-40 spike). libghostty attaches its own Metal layer to this view (making
/// it layer-hosting), so this view must NOT set `wantsLayer` itself. Coordinates handed
/// to libghostty use a top-left origin, so mouse `y` is flipped from AppKit's.
final class GhosttyHostView: NSView {
    weak var owner: GhosttySurface?
    var surfacePtr: ghostty_surface_t?

    private var trackingArea: NSTrackingArea?

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
        let action: ghostty_input_action_e = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
        sendKey(surfacePtr, action, event, text: event.ghosttyCharacters)
    }

    override func keyUp(with event: NSEvent) {
        guard let surfacePtr else { return }
        sendKey(surfacePtr, GHOSTTY_ACTION_RELEASE, event, text: nil)
    }

    private func sendKey(
        _ surfacePtr: ghostty_surface_t, _ action: ghostty_input_action_e, _ event: NSEvent, text: String?
    ) {
        var key = event.ghosttyKeyEvent(action)
        // Encode UTF-8 text only for non-control input; libghostty encodes control
        // characters itself from the keycode + mods (so ctrl+key stays correct).
        if let text, let first = text.utf8.first, first >= 0x20 {
            text.withCString {
                key.text = $0
                _ = ghostty_surface_key(surfacePtr, key)
            }
        } else {
            _ = ghostty_surface_key(surfacePtr, key)
        }
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
        // Packed scroll mods: bit 0 = high-precision. Momentum phases are omitted for the spike.
        let mods: ghostty_input_scroll_mods_t = precise ? 1 : 0
        ghostty_surface_mouse_scroll(surfacePtr, x, y, mods)
    }
}

extension NSEvent {
    /// Ghostty modifier bitmask from AppKit modifier flags.
    var ghosttyMods: ghostty_input_mods_e {
        var mods = GHOSTTY_MODS_NONE.rawValue
        if modifierFlags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
        if modifierFlags.contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
        if modifierFlags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
        if modifierFlags.contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }
        if modifierFlags.contains(.capsLock) { mods |= GHOSTTY_MODS_CAPS.rawValue }
        return ghostty_input_mods_e(mods)
    }

    /// A Ghostty key event carrying the physical keycode + mods; libghostty maps the
    /// keycode to its own key enum. Text is set separately by the caller. Ported from
    /// Ghostty's own `NSEvent.ghosttyKeyEvent`.
    func ghosttyKeyEvent(_ action: ghostty_input_action_e) -> ghostty_input_key_s {
        var key = ghostty_input_key_s()
        key.action = action
        key.keycode = UInt32(keyCode)
        key.text = nil
        key.composing = false
        key.mods = ghosttyMods
        // Heuristic that has held for years in Ghostty: control and command never
        // contribute to text translation; everything else may.
        key.consumed_mods = ghostty_input_mods_e(
            ghosttyMods.rawValue & ~(GHOSTTY_MODS_CTRL.rawValue | GHOSTTY_MODS_SUPER.rawValue))
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
