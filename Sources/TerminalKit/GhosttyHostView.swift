import AppKit
import GhosttyKit

// Never sets `wantsLayer`: libghostty attaches its own Metal layer, making this view layer-hosting.
final class GhosttyHostView: NSView {
    weak var owner: GhosttySurface?
    var surfacePtr: ghostty_surface_t?

    var scrollMultiplier: Double = 1.5

    private var trackingArea: NSTrackingArea?

    private var screenChangeObserver: NSObjectProtocol?
    private var occlusionObserver: NSObjectProtocol?
    private var appActivationObserver: NSObjectProtocol?

    // `.iBeam` at rest because libghostty emits `MOUSE_SHAPE` only on a change.
    private var desiredCursor: NSCursor = .iBeam

    var markedText = NSMutableAttributedString()

    var keyTextAccumulator: [String]?

    var accessibilityContentsCache: (value: String, fetchedAt: ContinuousClock.Instant)?

    override var acceptsFirstResponder: Bool { true }

    // AppKit turns a drag over this view into a window move before the view sees it.
    override var mouseDownCanMoveWindow: Bool { false }

    // A count, not a flag: overlapping animations would otherwise unfreeze panes another still animates.
    private var sizeSyncHolds = 0

    var isSizeSyncSuspended: Bool { sizeSyncHolds > 0 }

    func setSizeSyncSuspended(_ suspended: Bool) {
        if suspended {
            flushPendingSizePush()
            sizeSyncHolds += 1
            return
        }
        guard sizeSyncHolds > 0 else { return }
        sizeSyncHolds -= 1
        if sizeSyncHolds == 0 { syncSizeAndScale() }
    }

    func syncSizeAndScale() {
        if let surfacePtr {
            let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
            ghostty_surface_set_content_scale(surfacePtr, scale, scale)
        }
        guard !isSizeSyncSuspended else { return }
        scheduleSizePush()
    }

    private var hasPendingSizePush = false

    private(set) var sizePushesForTesting = 0

    private(set) var lastPushedFrameForTesting: NSSize?

    // Coalesced to the turn's end: a narrow intermediate frame rewraps scrollback that libghostty then evicts.
    private func scheduleSizePush() {
        guard !hasPendingSizePush else { return }
        hasPendingSizePush = true
        DispatchQueue.main.async { [weak self] in
            guard let self, self.hasPendingSizePush else { return }
            self.hasPendingSizePush = false
            self.pushSize()
        }
    }

    private func flushPendingSizePush() {
        guard hasPendingSizePush else { return }
        hasPendingSizePush = false
        pushSize()
    }

    // Skips a detached view, where `convertToBacking` is the identity and the size lands at half on Retina.
    private func pushSize() {
        guard !isSizeSyncSuspended else { return }
        sizePushesForTesting += 1
        lastPushedFrameForTesting = bounds.size
        guard window != nil else { return }
        let backing = convertToBacking(bounds).size
        guard backing.width >= 1, backing.height >= 1 else { return }
        guard let surfacePtr else { return }
        ghostty_surface_set_size(surfacePtr, UInt32(backing.width), UInt32(backing.height))
        owner?.reportGridIfChanged()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        syncSizeAndScale()
    }

    // libghostty sets `contentsScale` once, and AppKit only syncs layer-backed views, not layer-hosting ones.
    private func syncLayerContentsScale() {
        guard let window else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contentsScale = window.backingScaleFactor
        CATransaction.commit()
    }

    // libghostty picks the vsync display once at renderer init, so a moved window must re-point it.
    func syncDisplayID() {
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

    // Nothing else tells libghostty the view is hidden, so a covered window would keep drawing its shader at 120fps.
    func syncOcclusion() {
        guard let surfacePtr else { return }
        ghostty_surface_set_occlusion(surfacePtr, window?.occlusionState.contains(.visible) ?? false)
    }

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

    // Reactivation synthesizes no `mouseEntered`, so a parked pointer stays at (-1, -1) and blocks mouse reports.
    private func observeAppActivation() {
        guard appActivationObserver == nil else { return }
        appActivationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.reportPointerIfOverThisPane() }
    }

    private func reportPointerIfOverThisPane() {
        guard let surfacePtr, let window else { return }
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
        syncLayerContentsScale()
        syncSizeAndScale()
    }

    // AppKit does not reliably send `viewDidChangeBackingProperties` on a display move (ghostty-org/ghostty#2731).
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

    // `.activeInActiveApp`, unlike Ghostty's `.activeAlways`: tracking stops while the app is in back.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    // Reports to the owner only; calling `ghostty_surface_set_focus` here races the owner's effective focus.
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

    var lastPerformKeyEvent: TimeInterval?

    func eventToRedispatch(_ current: NSEvent?) -> NSEvent? {
        guard let current, lastPerformKeyEvent == current.timestamp else { return nil }
        return current
    }

    // AppKit's key-equivalent dispatch claims Ctrl-Return and Ctrl-/ before `keyDown` runs.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        guard window?.firstResponder === self else { return false }
        guard let equivalent = keyEquivalentEvent(for: event) else { return false }
        keyDown(with: equivalent)
        return true
    }

    // Command and control keys are declined once and matched by timestamp, so a menu item wins the first pass.
    func keyEquivalentEvent(for event: NSEvent) -> NSEvent? {
        let equivalent: String
        switch event.charactersIgnoringModifiers {
        case "\r":
            guard event.modifierFlags.contains(.control) else { return nil }
            equivalent = "\r"

        case "/":
            guard event.modifierFlags.contains(.control),
                event.modifierFlags.isDisjoint(with: [.shift, .command, .option])
            else { return nil }
            equivalent = "_"

        default:
            guard event.timestamp != 0 else { return nil }
            guard event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control)
            else {
                lastPerformKeyEvent = nil
                return nil
            }
            if let lastPerformKeyEvent {
                self.lastPerformKeyEvent = nil
                if lastPerformKeyEvent == event.timestamp {
                    equivalent = event.characters ?? ""
                    break
                }
            }
            lastPerformKeyEvent = event.timestamp
            return nil
        }

        return NSEvent.keyEvent(
            with: .keyDown, location: event.locationInWindow, modifierFlags: event.modifierFlags,
            timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil,
            characters: equivalent, charactersIgnoringModifiers: equivalent,
            isARepeat: event.isARepeat, keyCode: event.keyCode)
    }

    // Rebuilds the event only when mods change: AppKit keys CJK composition off event identity.
    override func keyDown(with event: NSEvent) {
        guard let surfacePtr else { return }
        if markedText.length == 0, event.isSoftNewline {
            ghostty_surface_text(surfacePtr, "\n", 1)
            return
        }

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

        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }

        let markedTextBefore = markedText.length > 0
        let keyboardIdBefore: String? = markedTextBefore ? nil : KeyboardLayout.id

        lastPerformKeyEvent = nil

        interpretKeyEvents([translationEvent])

        if !markedTextBefore, keyboardIdBefore != KeyboardLayout.id { return }

        syncPreedit(clearIfNeeded: markedTextBefore)

        if let accumulated = keyTextAccumulator, !accumulated.isEmpty {
            recordKeyPress(for: event)
            for text in accumulated {
                _ = keyAction(action, event: event, translationEvent: translationEvent, text: text)
            }
        } else {
            let composing = markedText.length > 0 || markedTextBefore
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

    // An unpaired release breaks kitty-protocol programs, and `KeyInterceptor` swallows presses only.
    private var reportedKeys: Set<UInt16> = []

    func recordKeyPress(for event: NSEvent) { reportedKeys.insert(event.keyCode) }

    func retireKeyPress(for event: NSEvent) -> Bool { reportedKeys.remove(event.keyCode) != nil }

    // Leaves `reportedKeys`: libghostty releases only its single `pressed_key` on blur.
    func forgetHeldModifiers() { reportedModifierKeys.removeAll() }

    // Nothing upstream forwards modifier moves, and kitty's report-all-keys mode needs them.
    override func flagsChanged(with event: NSEvent) {
        guard let action = modifierActionToForward(for: event) else { return }
        _ = keyAction(action, event: event)
    }

    // Keyed by keyCode so both sides of a modifier pair independently under the kitty protocol.
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

    private var reportedModifierKeys: Set<UInt16> = []

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

    // AppKit reports resulting state, so the moved side's device flag sets direction; no device flag reads as a press.
    static func modifierTransition(for event: NSEvent) -> ghostty_input_action_e? {
        guard let modifier = modifierKeyCodes[event.keyCode] else { return nil }
        guard event.ghosttyMods.rawValue & modifier.named != 0 else { return GHOSTTY_ACTION_RELEASE }
        let raw = event.modifierFlags.rawValue
        if let side = modifier.side, raw & side != 0 { return GHOSTTY_ACTION_PRESS }
        if let other = modifier.otherSide, raw & other != 0 { return GHOSTTY_ACTION_RELEASE }
        return GHOSTTY_ACTION_PRESS
    }

    @discardableResult
    func keyAction(
        _ action: ghostty_input_action_e, event: NSEvent,
        translationEvent: NSEvent? = nil, text: String? = nil, composing: Bool = false
    ) -> Bool {
        guard let surfacePtr else { return false }
        var key = event.ghosttyKeyEvent(action, translationMods: translationEvent?.modifierFlags)
        key.composing = composing
        if let text, let first = text.utf8.first, first >= 0x20 {
            return text.withCString {
                key.text = $0
                return ghostty_surface_key(surfacePtr, key)
            }
        }
        return ghostty_surface_key(surfacePtr, key)
    }

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

    // Middle-click paste is not wired: `supports_selection_clipboard` is false on macOS.
    override func otherMouseDown(with event: NSEvent) {
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

    // Our tracking stands down with the app, so a drag ending after deactivation never gets its exit.
    private func settleSkippedExit(_ event: NSEvent) {
        guard let surfacePtr, NSEvent.pressedMouseButtons == 0, !NSApp.isActive else { return }
        ghostty_surface_mouse_pos(surfacePtr, -1, -1, event.ghosttyMods)
    }

    // AppKit numbers buttons in hardware order; libghostty uses X11 numbering, which diverges past middle.
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

    // libghostty gates mouse reports on an in-viewport position, which `mouseExited` set to (-1, -1).
    override func mouseEntered(with event: NSEvent) { reportMousePos(event) }

    override func mouseExited(with event: NSEvent) {
        guard let surfacePtr, NSEvent.pressedMouseButtons == 0 else { return }
        ghostty_surface_mouse_pos(surfacePtr, -1, -1, event.ghosttyMods)
    }

    private func reportMousePos(_ event: NSEvent) {
        guard let surfacePtr else { return }
        let pos = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surfacePtr, pos.x, frame.height - pos.y, event.ghosttyMods)
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: desiredCursor) }

    func applyMouseShape(_ shape: ghostty_action_mouse_shape_e) {
        let cursor = Self.nsCursor(for: shape)
        guard cursor != desiredCursor else { return }
        desiredCursor = cursor
        window?.invalidateCursorRects(for: self)
    }

    // `setHiddenUntilMouseMoves` cannot strand a hidden cursor the way an unbalanced `hide()` can.
    func setCursorVisible(_ visible: Bool) {
        NSCursor.setHiddenUntilMouseMoves(!visible)
    }

    // macOS 14 floor rules out `NSView.pointerStyle`; shapes with no classic cursor fall back to `.arrow`.
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

    // Sets only the precision bit: ghostty ignores momentum phase, and macOS's decaying deltas give the coast.
    override func scrollWheel(with event: NSEvent) {
        guard let surfacePtr else { return }
        var x = event.scrollingDeltaX
        var y = event.scrollingDeltaY
        let precise = event.hasPreciseScrollingDeltas
        if precise {
            x *= scrollMultiplier
            y *= scrollMultiplier
        }
        let mods: ghostty_input_scroll_mods_t = precise ? 1 : 0
        ghostty_surface_mouse_scroll(surfacePtr, x, y, mods)
    }
}

extension NSScreen {
    var displayID: UInt32? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32
    }
}

extension NSEvent {
    // Shift exclusively, so other Shift+Enter chords still reach libghostty's key encoder.
    var isSoftNewline: Bool {
        guard keyCode == 36 else { return false }
        let active = modifierFlags.intersection([.shift, .control, .option, .command])
        return active == .shift
    }

    var ghosttyMods: ghostty_input_mods_e { Self.ghosttyMods(modifierFlags) }

    static func ghosttyMods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var mods = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { mods |= GHOSTTY_MODS_CAPS.rawValue }
        return ghostty_input_mods_e(mods)
    }

    // Key events only: libghostty compares stripped mouse mods against raw ones, so sided bits rebuild the grid.
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

    static func eventModifierFlags(mods: ghostty_input_mods_e) -> NSEvent.ModifierFlags {
        var flags = NSEvent.ModifierFlags(rawValue: 0)
        if mods.rawValue & GHOSTTY_MODS_SHIFT.rawValue != 0 { flags.insert(.shift) }
        if mods.rawValue & GHOSTTY_MODS_CTRL.rawValue != 0 { flags.insert(.control) }
        if mods.rawValue & GHOSTTY_MODS_ALT.rawValue != 0 { flags.insert(.option) }
        if mods.rawValue & GHOSTTY_MODS_SUPER.rawValue != 0 { flags.insert(.command) }
        return flags
    }

    // Control and command never count toward `consumed_mods`, as in Ghostty's own app.
    func ghosttyKeyEvent(
        _ action: ghostty_input_action_e, translationMods: NSEvent.ModifierFlags? = nil
    ) -> ghostty_input_key_s {
        var key = ghostty_input_key_s()
        key.action = action
        key.keycode = UInt32(keyCode)
        key.text = nil
        key.composing = false
        key.mods = ghosttySidedMods
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
