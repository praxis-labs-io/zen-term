import AppKit
import GhosttyKit

/// The `NSView` libghostty renders into and that forwards input to a `GhosttySurface`'s
/// surface. libghostty attaches its own Metal layer to this view (making
/// it layer-hosting), so this view must NOT set `wantsLayer` itself. Coordinates handed
/// to libghostty use a top-left origin, so mouse `y` is flipped from AppKit's.
final class GhosttyHostView: NSView {
    weak var owner: GhosttySurface?
    var surfacePtr: ghostty_surface_t?

    /// Precise-scroll feel multiplier, dialed from `scroll-multiplier` in the user config
    /// (default 1.5×). Set by `GhosttySurface.start`.
    var scrollMultiplier: Double = 1.5

    private var trackingArea: NSTrackingArea?

    /// Token for the `NSWindow.didChangeScreenNotification` observer (see `observeScreenChanges`).
    private var screenChangeObserver: NSObjectProtocol?
    private var occlusionObserver: NSObjectProtocol?

    /// The cursor libghostty last asked for via `GHOSTTY_ACTION_MOUSE_SHAPE` (I-beam over
    /// text, pointing hand over a ⌘-hovered link, …). Applied through cursor rects
    /// (`resetCursorRects`) so AppKit owns when to assert it — the idiomatic mechanism, rather
    /// than fighting `NSCursor.current` with imperative `.set()` calls.
    ///
    /// Defaults to `.iBeam`, not `.arrow`: libghostty only emits `MOUSE_SHAPE` on a *change*,
    /// so before the first one the resting state over the terminal grid must already be the
    /// text cursor (matching ghostty's own `.horizontalText` default) — otherwise the pointer
    /// is the plain arrow until some mode change kicks it.
    private var desiredCursor: NSCursor = .iBeam

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

    // The host window is chromeless and drags by its background
    // (`isMovableByWindowBackground`). AppKit converts any click-drag over a subview whose
    // `mouseDownCanMoveWindow` is true into a window move before the view sees the event —
    // and NSView defaults to true — so drags over terminal content moved the window instead
    // of reaching libghostty's selection. Opt out so click-drag here selects text; the
    // window still drags by the gutters, window inset, and chrome around the panes.
    override var mouseDownCanMoveWindow: Bool { false }

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

    /// Match the Metal layer's `contentsScale` to the window's backing scale factor.
    ///
    /// libghostty sets `contentsScale` once, at renderer init, and thereafter sizes every
    /// render target from `layer.bounds * layer.contentsScale`. It never re-reads the scale
    /// we push through `ghostty_surface_set_content_scale`. AppKit doesn't sync it for us
    /// either: libghostty attaches its own Metal layer, making this view layer-*hosting*, and
    /// the automatic sync only applies to layer-backed views. Left alone, a window moved to a
    /// display of a different density keeps rendering at the old pixel density and Core
    /// Animation rescales the result (ZEN-247).
    ///
    /// Ref: High Resolution Guidelines for OS X.
    private func syncLayerContentsScale() {
        guard let window else { return }
        CATransaction.begin()
        // Without this, Core Animation animates the scale change and it reads as jank.
        CATransaction.setDisableActions(true)
        layer?.contentsScale = window.backingScaleFactor
        CATransaction.commit()
    }

    /// Point libghostty's vsync display link at the display this view is actually on, so the
    /// render loop follows that display's refresh rate. libghostty creates the display link at
    /// renderer init and never revisits it, so without this a surface stays pinned to whatever
    /// display it defaulted to — both for one born on a secondary display and for one whose
    /// window later moves.
    func syncDisplayID() {
        // No sentinel when the id is missing: 0 is kCGNullDirectDisplay, which only makes
        // libghostty fail the display-link call and log for it.
        guard let surfacePtr, let displayID = window?.screen?.displayID else { return }
        ghostty_surface_set_display_id(surfacePtr, displayID)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observeScreenChanges()
        observeOcclusion()
        syncDisplayID()
        syncOcclusion()
        syncLayerContentsScale()
        syncSizeAndScale()
    }

    /// Tell libghostty whether this surface is actually on screen. Its render thread skips every
    /// frame while a surface is invisible (`renderer/Thread.zig`, `drawFrame`), and nothing else
    /// moves that flag — so without this a covered or minimized window keeps drawing, which with
    /// a cursor shader means a full-screen post-process pass at 120fps for nobody (ZEN-271).
    ///
    /// A nil window reads as not visible: an unmounted view has nothing to show.
    func syncOcclusion() {
        guard let surfacePtr else { return }
        ghostty_surface_set_occlusion(surfacePtr, window?.occlusionState.contains(.visible) ?? false)
    }

    /// Registered once, for any window, and filtered to ours — the same shape
    /// `observeScreenChanges` uses, and for the same reason: this view is re-parented across
    /// windows over its life.
    private func observeOcclusion() {
        guard occlusionObserver == nil else { return }
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let self, let window = self.window, notification.object as? NSWindow === window
            else { return }
            self.syncOcclusion()
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        // Ahead of syncSizeAndScale: the size libghostty derives comes off the layer scale.
        syncLayerContentsScale()
        syncSizeAndScale()
    }

    /// AppKit doesn't reliably send `viewDidChangeBackingProperties` when a window moves to a
    /// display with a different backing scale (ghostty-org/ghostty#2731), so drive that path
    /// off the window's screen change as well. Registered once, for any window: this view is
    /// re-parented across windows over its life, and the handler filters to ours.
    private func observeScreenChanges() {
        guard screenChangeObserver == nil else { return }
        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeScreenNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let self, let window = self.window, notification.object as? NSWindow === window
            else { return }
            self.windowDidChangeScreen()
        }
    }

    private func windowDidChangeScreen() {
        syncDisplayID()
        // The same work `viewDidChangeBackingProperties` does, run directly rather than by
        // calling that override: AppKit owns when its lifecycle methods fire. It runs next
        // turn, not now, because the window's backing scale factor isn't updated yet when
        // this notification lands.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.syncLayerContentsScale()
            self.syncSizeAndScale()
        }
    }

    deinit {
        if let screenChangeObserver {
            NotificationCenter.default.removeObserver(screenChangeObserver)
        }
        if let occlusionObserver {
            NotificationCenter.default.removeObserver(occlusionObserver)
        }
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
        owner?.focusDidChange(true)
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if let surfacePtr { ghostty_surface_set_focus(surfacePtr, false) }
        owner?.focusDidChange(false)
        return ok
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        guard let surfacePtr else { return }
        // Shift+Enter → LF so multiline-aware CLIs treat it as a soft newline while
        // plain Enter (CR) still submits — the convention `claude /terminal-setup`
        // writes. keyCode 36 = kVK_Return.
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

    // MARK: Cursor

    override func resetCursorRects() { addCursorRect(bounds, cursor: desiredCursor) }

    /// Apply the cursor libghostty asked for (`GHOSTTY_ACTION_MOUSE_SHAPE`). Only re-arms the
    /// cursor rect on a real change so we don't thrash AppKit's cursor management every move.
    func applyMouseShape(_ shape: ghostty_action_mouse_shape_e) {
        let cursor = Self.nsCursor(for: shape)
        guard cursor != desiredCursor else { return }
        desiredCursor = cursor
        window?.invalidateCursorRects(for: self)
    }

    /// Show or hide the pointer for `GHOSTTY_ACTION_MOUSE_VISIBILITY`.
    /// `setHiddenUntilMouseMoves` is the right primitive for mouse-hide-while-typing: it
    /// auto-restores on the next mouse move (no balanced unhide to leak), so a surface torn
    /// down or detached while hidden can never strand a globally invisible cursor — the fragile
    /// case a `hide()`/`unhide()` refcount hits when the chrome detaches a persistent pane.
    func setCursorVisible(_ visible: Bool) {
        NSCursor.setHiddenUntilMouseMoves(!visible)
    }

    /// Map a libghostty mouse shape to a classic `NSCursor`. macOS 14 is our floor, so we
    /// can't use `NSView.pointerStyle` (macOS 15+) the way ghostty's own app does. The
    /// diagonal resizes, progress/wait, and zoom shapes have no classic cursor, so they fall
    /// back to `.arrow` rather than reaching for a private cursor.
    static func nsCursor(for shape: ghostty_action_mouse_shape_e) -> NSCursor {
        switch shape {
        case GHOSTTY_MOUSE_SHAPE_TEXT: return .iBeam
        case GHOSTTY_MOUSE_SHAPE_VERTICAL_TEXT: return .iBeamCursorForVerticalLayout
        case GHOSTTY_MOUSE_SHAPE_POINTER: return .pointingHand
        case GHOSTTY_MOUSE_SHAPE_CROSSHAIR, GHOSTTY_MOUSE_SHAPE_CELL: return .crosshair
        case GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED, GHOSTTY_MOUSE_SHAPE_NO_DROP:
            return .operationNotAllowed
        case GHOSTTY_MOUSE_SHAPE_GRAB: return .openHand
        case GHOSTTY_MOUSE_SHAPE_GRABBING, GHOSTTY_MOUSE_SHAPE_ALL_SCROLL: return .closedHand
        case GHOSTTY_MOUSE_SHAPE_COPY: return .dragCopy
        case GHOSTTY_MOUSE_SHAPE_ALIAS: return .dragLink
        case GHOSTTY_MOUSE_SHAPE_CONTEXT_MENU: return .contextualMenu
        case GHOSTTY_MOUSE_SHAPE_N_RESIZE, GHOSTTY_MOUSE_SHAPE_S_RESIZE,
            GHOSTTY_MOUSE_SHAPE_NS_RESIZE, GHOSTTY_MOUSE_SHAPE_ROW_RESIZE:
            return .resizeUpDown
        case GHOSTTY_MOUSE_SHAPE_E_RESIZE, GHOSTTY_MOUSE_SHAPE_W_RESIZE,
            GHOSTTY_MOUSE_SHAPE_EW_RESIZE, GHOSTTY_MOUSE_SHAPE_COL_RESIZE:
            return .resizeLeftRight
        default: return .arrow
        }
    }

    override func scrollWheel(with event: NSEvent) {
        guard let surfacePtr else { return }
        var x = event.scrollingDeltaX
        var y = event.scrollingDeltaY
        let precise = event.hasPreciseScrollingDeltas
        if precise {
            x *= scrollMultiplier  // subjective feel multiplier, matching Ghostty's own app
            y *= scrollMultiplier
        }
        // Packed scroll mods: bit 0 = high-precision. Only the precision bit is set: ghostty's core
        // ignores the momentum phase entirely (verified in 1.3.1 — zero references), so forwarding it
        // changes nothing. The flick coast comes from macOS's own decaying deltas; ghostty then
        // scrolls in whole cells (it carries a sub-cell remainder but never renders fractional rows),
        // which is the deceleration stutter and needs upstream fractional-line rendering to smooth.
        let mods: ghostty_input_scroll_mods_t = precise ? 1 : 0
        ghostty_surface_mouse_scroll(surfacePtr, x, y, mods)
    }
}

extension NSScreen {
    /// The CoreGraphics display ID for this screen, which is what libghostty wants for
    /// `ghostty_surface_set_display_id` (it drives the vsync display link).
    var displayID: UInt32? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32
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
