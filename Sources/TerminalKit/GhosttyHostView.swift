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
    private var appActivationObserver: NSObjectProtocol?

    /// The cursor libghostty last asked for, applied through cursor rects so AppKit owns when to
    /// assert it. Defaults to `.iBeam` rather than `.arrow` because libghostty only emits
    /// `MOUSE_SHAPE` on a *change*, so the resting state has to be right before the first one.
    private var desiredCursor: NSCursor = .iBeam

    // MARK: IME / dead-key composition state

    /// The whole preedit text the input method is still composing. libghostty tracks no internal
    /// caret sub-range, so this attributed string is the entire model.
    var markedText = NSMutableAttributedString()

    /// Non-nil only for the duration of a `keyDown`: it flags `insertText`/`setMarkedText`
    /// that they are being driven by `interpretKeyEvents` (queue the text) rather than by a
    /// standalone event like dictation or the character palette (commit it immediately).
    var keyTextAccumulator: [String]?

    // MARK: Accessibility state

    /// The screen contents last read for the accessibility conformance, and when. Lives here
    /// because extensions cannot hold storage; read and refreshed only by `screenContents()`
    /// in GhosttyHostViewAccessibility.swift, which evicts it lazily after 500ms.
    var accessibilityContentsCache: (value: String, fetchedAt: ContinuousClock.Instant)?

    override var acceptsFirstResponder: Bool { true }

    // AppKit turns a click-drag over any subview with this true into a window move before the
    // view sees the event, and NSView defaults to true, so terminal drags moved the chromeless
    // window instead of selecting. The window still drags by the gutters and chrome.
    override var mouseDownCanMoveWindow: Bool { false }

    // MARK: Size / scale

    /// How many chrome animations are currently holding this surface's grid. A count rather than a
    /// flag because the holders overlap, and with a flag whichever animation finished first
    /// unfroze panes another was still animating.
    private var sizeSyncHolds = 0

    /// Whether frame changes are currently held back from libghostty, so the grid keeps the size it
    /// had when the first holder took its hold. See `TerminalSurface.setSizeSyncSuspended`.
    var isSizeSyncSuspended: Bool { sizeSyncHolds > 0 }

    /// Take or release a hold on this surface's grid. The grid re-syncs when the last hold is
    /// released, so it always reconciles to whatever the frame actually landed on. A release
    /// without a matching hold is ignored rather than driving the count negative — a surface born
    /// mid-animation never took the hold, and leaving it unfrozen is the safe direction.
    func setSizeSyncSuspended(_ suspended: Bool) {
        if suspended {
            sizeSyncHolds += 1
            return
        }
        guard sizeSyncHolds > 0 else { return }
        sizeSyncHolds -= 1
        if sizeSyncHolds == 0 { syncSizeAndScale() }
    }

    /// Push the current backing size and content scale into libghostty. Called on every
    /// geometry or backing-store change; libghostty tolerates a zero size until the first
    /// real layout.
    func syncSizeAndScale() {
        guard let surfacePtr else { return }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        ghostty_surface_set_content_scale(surfacePtr, scale, scale)
        // The scale above still tracks (a display change mid-animation is not a reflow), but the
        // grid is frozen for the length of the chrome's animation — see `isSizeSyncSuspended`.
        guard !isSizeSyncSuspended else { return }
        // Skip zero sizes: the view has no bounds until the chrome lays it out, and
        // pushing 0×0 would collapse libghostty's sensible default grid to nothing.
        let backing = convertToBacking(bounds).size
        guard backing.width >= 1, backing.height >= 1 else { return }
        ghostty_surface_set_size(surfacePtr, UInt32(backing.width), UInt32(backing.height))
        owner?.reportGridIfChanged()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        syncSizeAndScale()
    }

    /// Match the Metal layer's `contentsScale` to the window's backing scale factor.
    ///
    /// libghostty sets it once at renderer init and never re-reads the scale we push, and AppKit's
    /// automatic sync only covers layer-*backed* views, not the layer-hosting one libghostty
    /// attaches. Left alone, a window moved to a display of another density keeps rendering at the
    /// old pixel density.
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
        observeAppActivation()
        syncDisplayID()
        syncOcclusion()
        syncLayerContentsScale()
        syncSizeAndScale()
    }

    /// Tell libghostty whether this surface is actually on screen. Nothing else moves that flag,
    /// so without this a covered or minimized window keeps drawing, which with a cursor shader is
    /// a full-screen post-process pass at 120fps for nobody. A nil window reads as not visible.
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

    /// AppKit stands the tracking area down with a synthesized `mouseExited` when the app
    /// deactivates, but reactivation synthesizes no matching `mouseEntered`, so a pointer parked
    /// over a pane stays at (-1, -1) and suppresses mouse reports until it physically moves.
    private func observeAppActivation() {
        guard appActivationObserver == nil else { return }
        appActivationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.reportPointerIfOverThisPane() }
    }

    private func reportPointerIfOverThisPane() {
        guard let surfacePtr, let window else { return }
        // Hit-test the screen's frontmost window first: a pane whose rect contains the pointer
        // may still be covered by another window, and a covered pane keeps its (-1, -1).
        guard
            NSWindow.windowNumber(at: NSEvent.mouseLocation, belowWindowWithWindowNumber: 0)
                == window.windowNumber
        else { return }
        let pos = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        guard bounds.contains(pos) else { return }
        ghostty_surface_mouse_pos(
            surfacePtr, pos.x, frame.height - pos.y, NSEvent.ghosttyMods(NSEvent.modifierFlags))
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        // Ahead of syncSizeAndScale: the size libghostty derives comes off the layer scale.
        syncLayerContentsScale()
        syncSizeAndScale()
    }

    /// AppKit doesn't reliably send `viewDidChangeBackingProperties` when a window moves to a
    /// display with a different backing scale (ghostty-org/ghostty#2731), so drive that path off
    /// the window's screen change too. Registered for any window, then filtered to ours, because
    /// this view is re-parented across windows over its life.
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
        // Next turn, not now: the window's backing scale factor isn't updated yet when this
        // notification lands.
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
        if let appActivationObserver {
            NotificationCenter.default.removeObserver(appActivationObserver)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        // `.activeInActiveApp`: a pane in a background window still gets hover reports, but
        // tracking stops with the rest of the app when it is not frontmost. Ghostty's
        // `.activeAlways` keeps reporting while backgrounded, and that gap is deliberate.
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    // MARK: Focus

    // Responder transitions report pane focus to the owner and nothing else. They must NOT call
    // `ghostty_surface_set_focus` themselves: libghostty is told `paneFocused && isAppActive`, and
    // a direct write here races the owner's, which is what left the first surface at launch
    // unfocused with a dead cursor.
    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        owner?.focusDidChange(true)
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        owner?.focusDidChange(false)
        return ok
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        guard let surfacePtr else { return }
        // Shift+Enter sends LF so multiline-aware CLIs read a soft newline while plain Enter
        // still submits. MUST stay ahead of the interpretKeyEvents hand-off so the IME can't
        // swallow it, and guarded on not-composing so a mid-preedit Enter still commits.
        if markedText.length == 0, event.isSoftNewline {
            ghostty_surface_text(surfacePtr, "\n", 1)
            return
        }

        // Apply ONLY the four named flags on top of the event's own modifierFlags. Deriving the
        // whole set from the ghostty bitmask drops capsLock and the hidden device/keypad bits,
        // which forces an event rebuild that breaks CJK composition, since AppKit's input system
        // keys off NSEvent object identity.
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
            // Composition produced final text, so send it as ordinary key input rather than as
            // composing. Recorded here rather than in `keyAction`, which also carries the release,
            // or higher up, where the early returns above would record a press nothing sent.
            recordKeyPress(for: event)
            for text in accumulated {
                _ = keyAction(action, event: event, translationEvent: translationEvent, text: text)
            }
        } else {
            // No composed text: an ordinary key. We ARE composing if a preedit is live, or
            // if one existed before this event — the latter catches a Backspace that only
            // cancels the composition and must NOT also delete a real char in the shell.
            let composing = markedText.length > 0 || markedTextBefore
            // A composing non-modifier encodes nothing (`key_encode.zig`, "when composing, the
            // only keys sent are plain modifiers"), so recording it would owe a release for a
            // press the program never saw. The mirror of `modifierActionToForward`'s
            // `!hasMarkedText()` guard.
            if !composing { recordKeyPress(for: event) }
            _ = keyAction(
                action, event: event, translationEvent: translationEvent,
                text: translationEvent.ghosttyCharacters, composing: composing)
        }
    }

    override func keyUp(with event: NSEvent) {
        guard retireKeyPress(for: event) else { return }
        _ = keyAction(GHOSTTY_ACTION_RELEASE, event: event)
    }

    /// The keys this surface has told libghostty are down, by keyCode. `reportedModifierKeys` for
    /// ordinary keys, and it exists for the same reason: a bare RELEASE for a PRESS the terminal
    /// never saw is a key event a program under the kitty keyboard protocol cannot reconcile.
    ///
    /// Three paths swallow a `keyDown` and cannot swallow the `keyUp` behind it. `KeyInterceptor`
    /// resolves a chord at its event monitor, ahead of the responder chain, and its monitor
    /// matches no `keyUp` at all. The soft-newline chord sends its own text and returns. An input
    /// method takes the key and switches layout. Pairing here covers all three, and any fourth.
    ///
    /// Held ⌘ chords hid this: macOS withholds `keyUp` while Command is down, so the release for
    /// a consumed ⌘ chord never arrives to be mispaired. A user-bound `ctrl+h` is where it shows.
    private var reportedKeys: Set<UInt16> = []

    /// libghostty is about to be told this key went down, so it is owed the release.
    func recordKeyPress(for event: NSEvent) { reportedKeys.insert(event.keyCode) }

    /// Whether libghostty is owed a release for this key, retiring the press if it is. An
    /// auto-repeat re-records the same keyCode, so one release still settles the whole hold.
    func retireKeyPress(for event: NSEvent) -> Bool { reportedKeys.remove(event.keyCode) != nil }

    /// Forget the modifiers this surface reported, because libghostty has already retired them.
    /// Called on the transition to unfocused (`GhosttySurface.syncFocus`): `focusCallback`
    /// releases both sides of every modifier its `pressed_key` carries, so holding on here would
    /// suppress the next real press as a duplicate.
    ///
    /// Deliberately does NOT touch `reportedKeys`. libghostty releases only its single
    /// `pressed_key` (`Surface.zig`), so a second key held at the same moment is still down as
    /// far as the program is concerned, and dropping our record would swallow the release it is
    /// still owed. A record left standing for a key released while we were away costs nothing:
    /// the next press of that key re-records it, and the release after that retires it.
    func forgetHeldModifiers() { reportedModifierKeys.removeAll() }

    /// Modifier presses and releases. AppKit delivers these as `flagsChanged` rather than
    /// `keyDown`/`keyUp`, and nothing upstream forwards them (`KeyInterceptor`'s monitor passes
    /// them straight through outside capture mode), so without this override libghostty is never
    /// told a modifier moved — and the kitty keyboard protocol's report-all-keys mode, which
    /// Helix and nvim-with-kitty-protocol rely on, reports no modifiers at all.
    ///
    /// Unhandled events are swallowed rather than passed up, matching Ghostty's own app: the
    /// only other consumer of `flagsChanged` in ZenTerm is the Settings keybind recorder, and
    /// that reads events from a local monitor, which runs ahead of the responder chain.
    override func flagsChanged(with event: NSEvent) {
        guard let action = modifierActionToForward(for: event) else { return }
        _ = keyAction(action, event: event)
    }

    /// What to forward to libghostty for a `flagsChanged`, or nil to send nothing. Updates the
    /// record of what this surface has said is down, so every release can be matched to the press
    /// that earned it.
    ///
    /// Three ordinary paths emit an unpaired event without that pairing, and all three land on a
    /// program under the kitty keyboard protocol as a key event it cannot reconcile:
    ///
    /// * **A preedit** swallows the press but not the release that follows it, once the
    ///   composition has ended. This is the failure `keyUp` guards against for the soft-newline
    ///   chord, in the same shape.
    /// * **A ⌘ chord that moves pane focus** lands the press on one surface and the release on
    ///   another: `KeyInterceptor` consumes the chord's `keyDown` at its event monitor, but
    ///   `flagsChanged` passes straight through to whichever surface is first responder at the
    ///   time, and by the release that is the pane the chord moved to.
    /// * **Caps lock** sets its flag on the key going down *and* on it coming back up, so the
    ///   naive path reports two presses and no release for as long as the lock is engaged.
    ///
    /// A release is forwarded even mid-composition, because libghostty is holding that press and
    /// suppressing it would strand the modifier down.
    ///
    /// Keyed by keyCode, so the two sides of one modifier pair independently. Keying it by the
    /// named modifier instead cost a real bug: left ⌘ down then right ⌘ down reported one press,
    /// because `GHOSTTY_MODS_SUPER` was already set, and releasing left first then reported a
    /// release for the *right* key that no press had earned. Under the kitty keyboard protocol
    /// the two sides are different keys, so a program sees a key it never saw go down.
    func modifierActionToForward(for event: NSEvent) -> ghostty_input_action_e? {
        guard let action = Self.modifierTransition(for: event) else { return nil }
        if action == GHOSTTY_ACTION_PRESS {
            guard !hasMarkedText(), !reportedModifierKeys.contains(event.keyCode) else { return nil }
            reportedModifierKeys.insert(event.keyCode)
        } else {
            guard reportedModifierKeys.remove(event.keyCode) != nil else { return nil }
        }
        return action
    }

    /// The modifier keys this surface has told libghostty are down, by keyCode. See
    /// `modifierActionToForward`.
    private var reportedModifierKeys: Set<UInt16> = []

    /// The modifier each `flagsChanged` keyCode moves: the ghostty bit it sets, the device flag
    /// for the side it sits on, and the flag for the opposite side. Caps lock is unsided and has
    /// neither.
    private static let modifierKeyCodes: [UInt16: (named: UInt32, side: UInt?, otherSide: UInt?)] = [
        0x39: (GHOSTTY_MODS_CAPS.rawValue, nil, nil),
        0x38: (GHOSTTY_MODS_SHIFT.rawValue, UInt(NX_DEVICELSHIFTKEYMASK), UInt(NX_DEVICERSHIFTKEYMASK)),
        0x3C: (GHOSTTY_MODS_SHIFT.rawValue, UInt(NX_DEVICERSHIFTKEYMASK), UInt(NX_DEVICELSHIFTKEYMASK)),
        0x3B: (GHOSTTY_MODS_CTRL.rawValue, UInt(NX_DEVICELCTLKEYMASK), UInt(NX_DEVICERCTLKEYMASK)),
        0x3E: (GHOSTTY_MODS_CTRL.rawValue, UInt(NX_DEVICERCTLKEYMASK), UInt(NX_DEVICELCTLKEYMASK)),
        0x3A: (GHOSTTY_MODS_ALT.rawValue, UInt(NX_DEVICELALTKEYMASK), UInt(NX_DEVICERALTKEYMASK)),
        0x3D: (GHOSTTY_MODS_ALT.rawValue, UInt(NX_DEVICERALTKEYMASK), UInt(NX_DEVICELALTKEYMASK)),
        0x37: (GHOSTTY_MODS_SUPER.rawValue, UInt(NX_DEVICELCMDKEYMASK), UInt(NX_DEVICERCMDKEYMASK)),
        0x36: (GHOSTTY_MODS_SUPER.rawValue, UInt(NX_DEVICERCMDKEYMASK), UInt(NX_DEVICELCMDKEYMASK)),
    ]

    /// Which modifier a `flagsChanged` moved and in which direction, or nil when its keyCode is
    /// not a modifier at all (the globe key, which AppKit also reports here).
    ///
    /// The whole difficulty is that AppKit reports the *resulting* modifier state, not which
    /// direction the key moved. With both shifts held, releasing one still leaves `.shift` set,
    /// so reading the named flag alone encodes that release as a second press. The device flag
    /// for the side whose key actually moved is what separates them.
    ///
    /// Ghostty's own app checks only the right-hand device flags and treats every left-modifier
    /// keyCode as a press whenever the named flag is set, so releasing left-shift while right is
    /// held reports a press there. macOS carries a flag for both sides, so this consults the side
    /// the keyCode names and stays symmetric. What it keeps from Ghostty is the fallback: an
    /// event carrying the named flag but *no* device flag at all still reads as a press, because
    /// the named flag is then the only evidence there is. Synthesized input (`CGEvent` from
    /// automation or accessibility tooling) arrives that way, and reading it as a release would
    /// tell the terminal a held modifier had come up.
    static func modifierTransition(for event: NSEvent) -> ghostty_input_action_e? {
        guard let modifier = modifierKeyCodes[event.keyCode] else { return nil }
        // The named flag is clear, so that modifier is fully up whichever side was let go.
        guard event.ghosttyMods.rawValue & modifier.named != 0 else { return GHOSTTY_ACTION_RELEASE }
        let raw = event.modifierFlags.rawValue
        if let side = modifier.side, raw & side != 0 { return GHOSTTY_ACTION_PRESS }
        // This side is up, and the other one is what is still holding the named flag set.
        if let other = modifier.otherSide, raw & other != 0 { return GHOSTTY_ACTION_RELEASE }
        return GHOSTTY_ACTION_PRESS
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
        settleSkippedExit(event)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let surfacePtr else { return super.rightMouseDown(with: event) }
        _ = ghostty_surface_mouse_button(surfacePtr, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, event.ghosttyMods)
    }

    override func rightMouseUp(with event: NSEvent) {
        guard let surfacePtr else { return super.rightMouseUp(with: event) }
        _ = ghostty_surface_mouse_button(surfacePtr, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, event.ghosttyMods)
        settleSkippedExit(event)
    }

    // Middle click and the side buttons. Without these, a program with mouse reporting on never
    // learns they were pressed. Middle-click paste is deliberately not wired: libghostty is told
    // `supports_selection_clipboard` is false on macOS, which is correct for the platform.
    override func otherMouseDown(with event: NSEvent) {
        // Focus the pane, the same as a left click: the button is reported to whichever pane was
        // hit, so without this the click lands in one pane and the next keystroke in another.
        owner?.reportFocusWanted()
        guard let surfacePtr else { return }
        _ = ghostty_surface_mouse_button(
            surfacePtr, GHOSTTY_MOUSE_PRESS, Self.mouseButton(for: event.buttonNumber), event.ghosttyMods)
    }

    override func otherMouseUp(with event: NSEvent) {
        guard let surfacePtr else { return }
        _ = ghostty_surface_mouse_button(
            surfacePtr, GHOSTTY_MOUSE_RELEASE, Self.mouseButton(for: event.buttonNumber), event.ghosttyMods)
        settleSkippedExit(event)
    }

    /// `mouseExited` skips its (-1, -1) while a button is down, since drags keep reporting past
    /// the edge. Ghostty can rely on a later real exit because its tracking is `.activeAlways`;
    /// ours stands down with the app, so a drag ending after the app deactivated would strand the
    /// last in-viewport position until the pointer re-crossed the pane.
    private func settleSkippedExit(_ event: NSEvent) {
        guard let surfacePtr, NSEvent.pressedMouseButtons == 0, !NSApp.isActive else { return }
        ghostty_surface_mouse_pos(surfacePtr, -1, -1, event.ghosttyMods)
    }

    /// Translate an AppKit `buttonNumber` to libghostty's button. AppKit numbers in hardware order
    /// while libghostty uses the X11 numbering a terminal reports, so the two diverge past the
    /// middle button rather than running parallel.
    static func mouseButton(for buttonNumber: Int) -> ghostty_input_mouse_button_e {
        switch buttonNumber {
        case 0: return GHOSTTY_MOUSE_LEFT
        case 1: return GHOSTTY_MOUSE_RIGHT
        case 2: return GHOSTTY_MOUSE_MIDDLE
        case 3: return GHOSTTY_MOUSE_EIGHT
        case 4: return GHOSTTY_MOUSE_NINE
        case 5: return GHOSTTY_MOUSE_SIX
        case 6: return GHOSTTY_MOUSE_SEVEN
        case 7: return GHOSTTY_MOUSE_FOUR
        case 8: return GHOSTTY_MOUSE_FIVE
        case 9: return GHOSTTY_MOUSE_TEN
        case 10: return GHOSTTY_MOUSE_ELEVEN
        default: return GHOSTTY_MOUSE_UNKNOWN
        }
    }

    override func mouseMoved(with event: NSEvent) { reportMousePos(event) }
    override func mouseDragged(with event: NSEvent) { reportMousePos(event) }
    override func rightMouseDragged(with event: NSEvent) { reportMousePos(event) }
    override func otherMouseDragged(with event: NSEvent) { reportMousePos(event) }

    // Restores a real position after `mouseExited` pushed (-1, -1): libghostty gates mouse
    // reporting on the position being inside the viewport, and when a window becomes key with
    // the pointer already over a pane, no `mouseMoved` arrives to correct it.
    override func mouseEntered(with event: NSEvent) { reportMousePos(event) }

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

    /// Show or hide the pointer. `setHiddenUntilMouseMoves` auto-restores on the next mouse move,
    /// so a surface torn down while hidden cannot strand a globally invisible cursor the way an
    /// unbalanced `hide()`/`unhide()` refcount would.
    func setCursorVisible(_ visible: Bool) {
        NSCursor.setHiddenUntilMouseMoves(!visible)
    }

    /// Map a libghostty mouse shape to a classic `NSCursor`. macOS 14 is our floor, so
    /// `NSView.pointerStyle` is out. Shapes with no classic cursor fall back to `.arrow` rather
    /// than reaching for a private one.
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
        // Packed scroll mods: bit 0 = high-precision. Only that bit is set, because ghostty's core
        // ignores the momentum phase entirely. The flick coast comes from macOS's own decaying
        // deltas.
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
    /// The Shift+Enter soft-newline chord: Return with Shift and no other modifier. Requiring
    /// shift *exclusively* leaves Ctrl/Cmd/Opt+Shift+Enter to reach libghostty's key encoder as
    /// real chords rather than collapsing them all to a bare LF.
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

    /// Ghostty modifier bitmask *plus which side* each modifier is on.
    ///
    /// **Key events only.** The kitty protocol encodes left and right as different keys, so a key
    /// event without these reports every right-hand modifier as its left-hand counterpart. The
    /// mouse callbacks must not get them: libghostty stores mouse mods with the sides stripped and
    /// compares that against the raw mods, so sided bits make the comparison permanently unequal
    /// and every event rebuilds the whole grid while a right-hand modifier is held.
    var ghosttySidedMods: ghostty_input_mods_e { Self.ghosttySidedMods(modifierFlags) }

    static func ghosttySidedMods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var mods = ghosttyMods(flags).rawValue
        let rawFlags = flags.rawValue
        if rawFlags & UInt(NX_DEVICERSHIFTKEYMASK) != 0 { mods |= GHOSTTY_MODS_SHIFT_RIGHT.rawValue }
        if rawFlags & UInt(NX_DEVICERCTLKEYMASK) != 0 { mods |= GHOSTTY_MODS_CTRL_RIGHT.rawValue }
        if rawFlags & UInt(NX_DEVICERALTKEYMASK) != 0 { mods |= GHOSTTY_MODS_ALT_RIGHT.rawValue }
        if rawFlags & UInt(NX_DEVICERCMDKEYMASK) != 0 { mods |= GHOSTTY_MODS_SUPER_RIGHT.rawValue }
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
        // Sided here and nowhere else: the key encoder needs to know left from right, and the
        // mouse path is actively harmed by it. See `ghosttySidedMods`.
        key.mods = ghosttySidedMods
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
