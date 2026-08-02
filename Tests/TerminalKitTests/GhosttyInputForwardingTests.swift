import AppKit
import GhosttyKit
import XCTest

@testable import TerminalKit

/// Two input events `GhosttyHostView` used to drop on the floor (ZEN-308): modifier press and
/// release, and every mouse button past left and right. Both are the silently-dead class — the
/// app looks completely normal, because the only thing that notices is a program running under
/// the kitty keyboard protocol or with mouse reporting on, inside the pane.
///
/// The coverage splits in two, because the two halves can fail independently:
///
/// * **Delivery** — that the override exists at all and takes the event. Driven through a real
///   window, because that is the only thing that proves AppKit routes the event here rather than
///   somewhere upstream. `NSResponder`'s default implementation of both events forwards up the
///   chain, so a recording superview sees exactly what `GhosttyHostView` declined to handle.
/// * **Translation** — what the event *means*. Pure, and where the subtle bugs are: which side
///   of the keyboard moved, and the fact that AppKit's button order stops matching libghostty's
///   past the middle button.
///
/// What neither half covers: that libghostty receives the call. These surfaces are pointer-less
/// on purpose (no Metal layer, no PTY, matching every other host-view test here), so the
/// `ghostty_surface_*` calls no-op. A wrong *argument* to a correctly-wired call would survive
/// this file; the runbook is where a real pane gets driven.
final class GhosttyInputForwardingTests: XCTestCase {
    private var window: NSWindow!
    private var parent: RecordingResponderView!
    private var view: GhosttyHostView!

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared

        // A window per test method, closed in tearDown. XCTest tears down no AppKit state between
        // cases, so one left open stays on screen for the rest of the run and a suite climbs to
        // dozens of live window-server surfaces, each test running under more load than the last
        // (ZEN-312).
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false)
        // Closed in tearDown, not ordered out, so the window-server surface goes with it
        // (ZEN-312). `isReleasedWhenClosed` defaults to true for a window built in code, so clear
        // it or the close frees one this suite still holds: that lands as a segfault later, inside
        // whatever unrelated test happens to be running when the reference is next touched.
        window.isReleasedWhenClosed = false
        parent = RecordingResponderView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        view = GhosttyHostView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        parent.addSubview(view)
        window.contentView = parent
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
    }

    override func tearDown() {
        window.close()
        window = nil
        parent = nil
        view = nil
        super.tearDown()
    }

    // MARK: Delivery

    func test_theSurfaceTakesModifierEvents_ratherThanPassingThemUp() throws {
        XCTAssertTrue(window.firstResponder === view, "the surface has to be first responder to receive keys")

        window.sendEvent(try flagsChanged(keyCode: 0x38, named: .shift, held: [UInt(NX_DEVICELSHIFTKEYMASK)]))

        XCTAssertEqual(
            parent.flagsChangedCount, 0,
            "a modifier press reaching the superview means GhosttyHostView never overrode "
                + "flagsChanged, so libghostty is never told the modifier moved")
    }

    func test_theSurfaceTakesMiddleClick_ratherThanPassingItUp() throws {
        window.sendEvent(try otherMouse(.otherMouseDown))
        window.sendEvent(try otherMouse(.otherMouseUp))
        window.sendEvent(try otherMouse(.otherMouseDragged))

        XCTAssertEqual(parent.otherMouseDownCount, 0, "otherMouseDown was not overridden")
        XCTAssertEqual(parent.otherMouseUpCount, 0, "otherMouseUp was not overridden")
        XCTAssertEqual(parent.otherMouseDraggedCount, 0, "otherMouseDragged was not overridden")
    }

    /// Enter and exit are what keep libghostty's viewport state honest: exit pushes (-1, -1) and
    /// enter restores a real position after a window or the app becomes active with the pointer
    /// already parked over a pane (ZEN-310). `NSWindow.sendEvent` routes tracking events by
    /// tracking number, and a synthesized event cannot match the live tracking area's, so these
    /// are dispatched at the view directly; `NSResponder`'s defaults still forward up the chain,
    /// so the recording superview sees exactly what a missing override would have declined to
    /// handle.
    func test_theSurfaceTakesEnterAndExit_ratherThanPassingThemUp() throws {
        view.mouseEntered(with: try enterExit(.mouseEntered))
        view.mouseExited(with: try enterExit(.mouseExited))

        XCTAssertEqual(
            parent.mouseEnteredCount, 0,
            "an enter reaching the superview means GhosttyHostView never overrode mouseEntered, "
                + "so the (-1, -1) a mouseExited pushed is never replaced with a real position")
        XCTAssertEqual(
            parent.mouseExitedCount, 0,
            "an exit reaching the superview means GhosttyHostView never overrode mouseExited, "
                + "so libghostty is never told the pointer left the viewport")
    }

    /// Middle click has to focus the pane it hits, the same as a left click does. AppKit
    /// hit-tests the button to whichever pane is under the cursor, so without this the button is
    /// reported to one pane while the keyboard stays pointed at another, and the user's next
    /// keystroke lands somewhere they did not click.
    func test_middleClickFocusesThePaneItHits() throws {
        let surface = GhosttySurface()
        let delegate = FocusRecordingDelegate()
        surface.delegate = delegate
        view.owner = surface

        window.sendEvent(try otherMouse(.otherMouseDown))

        XCTAssertEqual(delegate.focusRequests, 1, "the pane the button landed in must take focus")
    }

    /// The sided bits have to reach the key event itself, not merely exist as a function. This is
    /// what the kitty protocol reads to tell left from right.
    func test_theEncodedKeyEventCarriesTheSide() throws {
        let event = try flagsChanged(keyCode: 0x3C, named: .shift, held: [UInt(NX_DEVICERSHIFTKEYMASK)])
        let key = event.ghosttyKeyEvent(GHOSTTY_ACTION_PRESS)
        XCTAssertNotEqual(
            key.mods.rawValue & GHOSTTY_MODS_SHIFT_RIGHT.rawValue, 0,
            "a key event built from a right-shift press has to say it was the right one")
    }

    // MARK: Translation — which side moved

    func test_pressingAModifierReportsAPress() throws {
        let cases: [(name: String, keyCode: UInt16, named: NSEvent.ModifierFlags, side: UInt)] = [
            ("left shift", 0x38, .shift, UInt(NX_DEVICELSHIFTKEYMASK)),
            ("right shift", 0x3C, .shift, UInt(NX_DEVICERSHIFTKEYMASK)),
            ("left control", 0x3B, .control, UInt(NX_DEVICELCTLKEYMASK)),
            ("right control", 0x3E, .control, UInt(NX_DEVICERCTLKEYMASK)),
            ("left option", 0x3A, .option, UInt(NX_DEVICELALTKEYMASK)),
            ("right option", 0x3D, .option, UInt(NX_DEVICERALTKEYMASK)),
            ("left command", 0x37, .command, UInt(NX_DEVICELCMDKEYMASK)),
            ("right command", 0x36, .command, UInt(NX_DEVICERCMDKEYMASK)),
        ]
        for item in cases {
            let event = try flagsChanged(keyCode: item.keyCode, named: item.named, held: [item.side])
            XCTAssertEqual(
                GhosttyHostView.modifierTransition(for: event)?.action, GHOSTTY_ACTION_PRESS,
                "\(item.name) going down is a press")
        }
    }

    func test_releasingTheLastHeldModifierReportsARelease() throws {
        // Nothing held: AppKit reports the resulting state, which is a bare flag set.
        let event = try flagsChanged(keyCode: 0x38)
        XCTAssertEqual(GhosttyHostView.modifierTransition(for: event)?.action, GHOSTTY_ACTION_RELEASE)
    }

    /// The case the whole side-discrimination exists for, in both directions. With both shifts
    /// down and one released, `.shift` is *still* set — the other side is holding it up. Reading
    /// the named flag alone reports a second press, and a program under the kitty protocol then
    /// sees two presses and no release for a key the user let go of.
    func test_releasingOneSideWhileTheOtherIsHeldReportsARelease() throws {
        let leftReleased = try flagsChanged(
            keyCode: 0x38, named: .shift, held: [UInt(NX_DEVICERSHIFTKEYMASK)])
        XCTAssertEqual(
            GhosttyHostView.modifierTransition(for: leftReleased)?.action, GHOSTTY_ACTION_RELEASE,
            "left shift came up; right is what is still holding .shift set")

        let rightReleased = try flagsChanged(
            keyCode: 0x3C, named: .shift, held: [UInt(NX_DEVICELSHIFTKEYMASK)])
        XCTAssertEqual(
            GhosttyHostView.modifierTransition(for: rightReleased)?.action, GHOSTTY_ACTION_RELEASE,
            "right shift came up; left is what is still holding .shift set")
    }

    /// An event carrying the named flag but no device flag for either side. Synthesized input
    /// (`CGEvent` from automation or accessibility tooling) arrives this way, and reading a
    /// side-less event as a release would tell the terminal a modifier the user is holding had
    /// come up, so shift-selection and ctrl chords from that source would silently do nothing.
    func test_aModifierWithNoSideInformationReadsAsAPress() throws {
        let event = try flagsChanged(keyCode: 0x38, named: .shift)
        XCTAssertEqual(
            GhosttyHostView.modifierTransition(for: event)?.action, GHOSTTY_ACTION_PRESS,
            "the named flag is the only evidence there is, and it says shift is down")
    }

    /// Caps lock is the one modifier macOS does not side, so it has no device flag to consult and
    /// the named flag is the whole story.
    func test_capsLockUsesTheNamedFlagAlone() throws {
        XCTAssertEqual(
            GhosttyHostView.modifierTransition(for: try flagsChanged(keyCode: 0x39, named: .capsLock))?
                .action, GHOSTTY_ACTION_PRESS)
        XCTAssertEqual(
            GhosttyHostView.modifierTransition(for: try flagsChanged(keyCode: 0x39))?.action,
            GHOSTTY_ACTION_RELEASE)
    }

    /// The globe key also arrives as `flagsChanged`, and libghostty has no modifier for it.
    func test_aNonModifierKeyCodeIsNotAModifierTransition() throws {
        XCTAssertNil(GhosttyHostView.modifierTransition(for: try flagsChanged(keyCode: 0x3F)))
    }

    // MARK: Pairing a release to the press that earned it

    /// A release for a modifier this surface never pressed must not be forwarded. Two ordinary
    /// paths produce one: a ⌘ chord that moves pane focus lands the press on the old pane and the
    /// release on the new one, and a preedit swallows a press but not the release after it.
    func test_aReleaseWithNoMatchingPressIsNotForwarded() throws {
        let release = try flagsChanged(keyCode: 0x38, held: [])
        XCTAssertNil(
            view.modifierActionToForward(for: release),
            "nothing pressed shift on this surface, so libghostty must not be told it came up")

        // And the surface is not left in a state that swallows the next real press.
        let press = try flagsChanged(keyCode: 0x38, named: .shift, held: [UInt(NX_DEVICELSHIFTKEYMASK)])
        XCTAssertEqual(view.modifierActionToForward(for: press), GHOSTTY_ACTION_PRESS)
        XCTAssertEqual(view.modifierActionToForward(for: release), GHOSTTY_ACTION_RELEASE)
    }

    /// Caps lock sets its flag on the key going down and again on it coming back up. Forwarding
    /// both leaves a TUI holding caps for as long as the lock is engaged.
    func test_aSecondPressForAModifierAlreadyDownIsNotForwarded() throws {
        let down = try flagsChanged(keyCode: 0x39, named: .capsLock)
        XCTAssertEqual(view.modifierActionToForward(for: down), GHOSTTY_ACTION_PRESS)
        XCTAssertNil(view.modifierActionToForward(for: down), "the key coming back up is not a second press")

        let up = try flagsChanged(keyCode: 0x39)
        XCTAssertEqual(view.modifierActionToForward(for: up), GHOSTTY_ACTION_RELEASE)
        XCTAssertNil(view.modifierActionToForward(for: up), "and that release does not repeat either")
    }

    /// A preedit swallows the press, so the release that follows must be swallowed too. The
    /// release is only unpaired *because* the press was suppressed.
    func test_aModifierPressedDuringACompositionIsNeverReleased() throws {
        view.markedText.mutableString.setString("か")

        let press = try flagsChanged(keyCode: 0x38, named: .shift, held: [UInt(NX_DEVICELSHIFTKEYMASK)])
        XCTAssertNil(view.modifierActionToForward(for: press), "a modifier mid-preedit is the IME's")

        view.markedText.mutableString.setString("")
        let release = try flagsChanged(keyCode: 0x38)
        XCTAssertNil(
            view.modifierActionToForward(for: release),
            "libghostty was never told shift went down, so it must not be told it came up")
    }

    /// The other half: a modifier pressed *before* a composition starts is genuinely held by
    /// libghostty, so its release has to be forwarded even though a preedit is live. Suppressing
    /// it would strand the modifier down.
    func test_aModifierHeldIntoACompositionIsStillReleased() throws {
        let press = try flagsChanged(keyCode: 0x38, named: .shift, held: [UInt(NX_DEVICELSHIFTKEYMASK)])
        XCTAssertEqual(view.modifierActionToForward(for: press), GHOSTTY_ACTION_PRESS)

        view.markedText.mutableString.setString("か")
        let release = try flagsChanged(keyCode: 0x38)
        XCTAssertEqual(
            view.modifierActionToForward(for: release), GHOSTTY_ACTION_RELEASE,
            "libghostty is holding that press; the composition does not retire it")
    }

    // MARK: Pairing a release to the key press that earned it

    /// The same rule as the modifier ledger, for ordinary keys. `KeyInterceptor` resolves a chord
    /// at its event monitor, ahead of the responder chain, and matches no `keyUp` at all, so the
    /// release for a consumed `ctrl+h` arrives here for a press libghostty was never told about.
    func test_aKeyReleaseWithNoMatchingPressIsNotForwarded() throws {
        XCTAssertFalse(
            view.retireKeyPress(for: try key(.keyUp, "h", keyCode: 0x04)),
            "nothing pressed h on this surface, so libghostty must not be told it came up")
    }

    /// And the release the surface *does* owe is forwarded, once. `keyUp` is driven for real here:
    /// the ledger is what proves the override consulted it rather than sending unconditionally.
    func test_aKeyReleaseRetiresThePressItPairsWith() throws {
        view.recordKeyPress(for: try key(.keyDown, "h", keyCode: 0x04))
        view.keyUp(with: try key(.keyUp, "h", keyCode: 0x04))

        XCTAssertFalse(
            view.retireKeyPress(for: try key(.keyUp, "h", keyCode: 0x04)),
            "that release settled the press; a second one is unpaired like any other")
    }

    /// An auto-repeat re-reports the same key going down. One release still has to settle the
    /// whole hold, or every held key leaves a press stranded in libghostty.
    func test_aHeldKeyIsSettledByOneRelease() throws {
        for _ in 0..<3 { view.recordKeyPress(for: try key(.keyDown, "j", keyCode: 0x26)) }

        XCTAssertTrue(view.retireKeyPress(for: try key(.keyUp, "j", keyCode: 0x26)))
        XCTAssertFalse(view.retireKeyPress(for: try key(.keyUp, "j", keyCode: 0x26)))
    }

    /// Losing focus retires the ledger, because libghostty retires its own held keys in
    /// `focusCallback` and the releases are not coming back anyway: ⌘-Tab away with a key down
    /// and the `keyUp` lands in the other app.
    func test_losingFocusForgetsWhatWasHeld() throws {
        view.recordKeyPress(for: try key(.keyDown, "h", keyCode: 0x04))
        XCTAssertEqual(
            view.modifierActionToForward(
                for: try flagsChanged(keyCode: 0x38, named: .shift, held: [UInt(NX_DEVICELSHIFTKEYMASK)])),
            GHOSTTY_ACTION_PRESS)

        view.forgetHeldKeys()

        XCTAssertFalse(
            view.retireKeyPress(for: try key(.keyUp, "h", keyCode: 0x04)),
            "libghostty already released that key")
        XCTAssertEqual(
            view.modifierActionToForward(
                for: try flagsChanged(keyCode: 0x38, named: .shift, held: [UInt(NX_DEVICELSHIFTKEYMASK)])),
            GHOSTTY_ACTION_PRESS,
            "and the next real shift press must not be suppressed as a duplicate")
    }

    // MARK: Translation — sided modifier bits

    /// The key event has to carry the side: the kitty protocol encodes left and right as
    /// different keys, so without the sided bit every right-hand modifier arrives at the program
    /// as its left-hand counterpart.
    func test_sidedModsCarryTheSideOfTheModifier() {
        let right = NSEvent.ghosttySidedMods(sided(.shift, UInt(NX_DEVICERSHIFTKEYMASK)))
        XCTAssertNotEqual(right.rawValue & GHOSTTY_MODS_SHIFT.rawValue, 0, "shift is held")
        XCTAssertNotEqual(right.rawValue & GHOSTTY_MODS_SHIFT_RIGHT.rawValue, 0, "and it is the right one")

        let left = NSEvent.ghosttySidedMods(sided(.shift, UInt(NX_DEVICELSHIFTKEYMASK)))
        XCTAssertNotEqual(left.rawValue & GHOSTTY_MODS_SHIFT.rawValue, 0, "shift is held")
        XCTAssertEqual(
            left.rawValue & GHOSTTY_MODS_SHIFT_RIGHT.rawValue, 0,
            "the left shift must not set the right-hand bit")
    }

    /// And the plain mods must NOT carry it. libghostty stores its mouse mods as `Mods.binding()`,
    /// which strips the sides, then compares that stored value against whatever it is handed
    /// (`Surface.modsChanged`). A sided value can never equal a stripped one, so the guard never
    /// holds and every key event and mouse move while a right-hand modifier is down marks the
    /// whole grid dirty and rebuilds every row.
    func test_plainModsDoNotCarryTheSide_soLibghosttysMouseGuardStillHolds() {
        let mods = NSEvent.ghosttyMods(sided(.shift, UInt(NX_DEVICERSHIFTKEYMASK)))
        XCTAssertNotEqual(mods.rawValue & GHOSTTY_MODS_SHIFT.rawValue, 0, "shift is still reported")
        XCTAssertEqual(
            mods.rawValue & GHOSTTY_MODS_SHIFT_RIGHT.rawValue, 0,
            "the mouse path must see no sided bits")
    }

    // MARK: Translation — mouse buttons

    /// AppKit numbers buttons in hardware order and libghostty names them by the X11 numbering a
    /// terminal reports. The two agree up to the middle button and then diverge, which is the
    /// only reason this mapping is a table rather than an offset.
    ///
    /// This table restates the switch it tests, so read the *oracle* as ghostty's
    /// `Input.MouseButton(fromNSEventButtonNumber:)`
    /// (`macos/Sources/Ghostty/Ghostty.Input.swift`, the `init(fromNSEventButtonNumber:)` case
    /// list), not this file. A pair transcribed wrong in both places would agree with itself and
    /// stay green; re-derive against that source rather than against the switch next door.
    func test_appKitButtonNumbersMapToTheButtonsATerminalReports() {
        let expected: [Int: ghostty_input_mouse_button_e] = [
            0: GHOSTTY_MOUSE_LEFT,
            1: GHOSTTY_MOUSE_RIGHT,
            2: GHOSTTY_MOUSE_MIDDLE,
            3: GHOSTTY_MOUSE_EIGHT,
            4: GHOSTTY_MOUSE_NINE,
            5: GHOSTTY_MOUSE_SIX,
            6: GHOSTTY_MOUSE_SEVEN,
            7: GHOSTTY_MOUSE_FOUR,
            8: GHOSTTY_MOUSE_FIVE,
            9: GHOSTTY_MOUSE_TEN,
            10: GHOSTTY_MOUSE_ELEVEN,
        ]
        for (buttonNumber, button) in expected {
            XCTAssertEqual(
                GhosttyHostView.mouseButton(for: buttonNumber), button,
                "AppKit button \(buttonNumber)")
        }
    }

    func test_aButtonWithNoTerminalEquivalentMapsToUnknown() {
        XCTAssertEqual(GhosttyHostView.mouseButton(for: 11), GHOSTTY_MOUSE_UNKNOWN)
        XCTAssertEqual(GhosttyHostView.mouseButton(for: -1), GHOSTTY_MOUSE_UNKNOWN)
    }

    // MARK: Events

    /// A named modifier plus the device flag for the side it sits on, the pair AppKit puts on a
    /// real event.
    private func sided(_ named: NSEvent.ModifierFlags, _ side: UInt) -> NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: named.rawValue | side)
    }

    /// A `flagsChanged` shaped the way AppKit actually delivers one: the modifier state that
    /// *results* from the key moving, carrying both the named flag and the device flag for
    /// whichever side is physically down. Setting only `.shift` would leave every side check
    /// untested, and would pass against code that never looks at a side at all.
    private func flagsChanged(
        keyCode: UInt16, named: NSEvent.ModifierFlags = [], held: [UInt] = []
    ) throws -> NSEvent {
        let raw = held.reduce(named.rawValue) { $0 | $1 }
        return try XCTUnwrap(
            NSEvent.keyEvent(
                with: .flagsChanged, location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: raw), timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "",
                charactersIgnoringModifiers: "", isARepeat: false, keyCode: keyCode))
    }

    private func key(
        _ type: NSEvent.EventType, _ characters: String, keyCode: UInt16
    ) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
    }

    /// `NSEvent.mouseEvent` has no `buttonNumber` parameter and every event it builds reports 0,
    /// so this can only prove the event is *delivered*. Which button it was is covered by the
    /// mapping tests above, against the number AppKit would have put on a real event.
    private func otherMouse(_ type: NSEvent.EventType) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.mouseEvent(
                with: type, location: NSPoint(x: 200, y: 150), modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                pressure: 1))
    }

    private func enterExit(_ type: NSEvent.EventType) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.enterExitEvent(
                with: type, location: NSPoint(x: 200, y: 150), modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0,
                userData: nil))
    }
}

/// Records what its subview declined to handle. `NSResponder`'s default `flagsChanged` and
/// `otherMouse*` implementations pass the event to `nextResponder`, so a count above zero here
/// means `GhosttyHostView` has no override for that event — which is the ZEN-308 bug exactly.
/// Counts focus requests reaching the seam. Every other delegate method has a default
/// implementation, so this only has to state the one it cares about.
private final class FocusRecordingDelegate: TerminalSurfaceDelegate {
    var focusRequests = 0
    func surfaceWantsFocus(_ s: TerminalSurface) { focusRequests += 1 }
}

private final class RecordingResponderView: NSView {
    var flagsChangedCount = 0
    var otherMouseDownCount = 0
    var otherMouseUpCount = 0
    var otherMouseDraggedCount = 0
    var mouseEnteredCount = 0
    var mouseExitedCount = 0

    override func flagsChanged(with event: NSEvent) { flagsChangedCount += 1 }
    override func otherMouseDown(with event: NSEvent) { otherMouseDownCount += 1 }
    override func otherMouseUp(with event: NSEvent) { otherMouseUpCount += 1 }
    override func otherMouseDragged(with event: NSEvent) { otherMouseDraggedCount += 1 }
    override func mouseEntered(with event: NSEvent) { mouseEnteredCount += 1 }
    override func mouseExited(with event: NSEvent) { mouseExitedCount += 1 }
}
