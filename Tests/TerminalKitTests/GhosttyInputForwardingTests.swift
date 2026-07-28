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

        // One window for the whole class, torn down in tearDown. Tests here open real windows,
        // and a window per test method is how a suite ends up with dozens on screen (ZEN-312).
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
                GhosttyHostView.modifierAction(for: event), GHOSTTY_ACTION_PRESS,
                "\(item.name) going down is a press")
        }
    }

    func test_releasingTheLastHeldModifierReportsARelease() throws {
        // Nothing held: AppKit reports the resulting state, which is a bare flag set.
        let event = try flagsChanged(keyCode: 0x38)
        XCTAssertEqual(GhosttyHostView.modifierAction(for: event), GHOSTTY_ACTION_RELEASE)
    }

    /// The case the whole side-discrimination exists for, in both directions. With both shifts
    /// down and one released, `.shift` is *still* set — the other side is holding it up. Reading
    /// the named flag alone reports a second press, and a program under the kitty protocol then
    /// sees two presses and no release for a key the user let go of.
    func test_releasingOneSideWhileTheOtherIsHeldReportsARelease() throws {
        let leftReleased = try flagsChanged(
            keyCode: 0x38, named: .shift, held: [UInt(NX_DEVICERSHIFTKEYMASK)])
        XCTAssertEqual(
            GhosttyHostView.modifierAction(for: leftReleased), GHOSTTY_ACTION_RELEASE,
            "left shift came up; right is what is still holding .shift set")

        let rightReleased = try flagsChanged(
            keyCode: 0x3C, named: .shift, held: [UInt(NX_DEVICELSHIFTKEYMASK)])
        XCTAssertEqual(
            GhosttyHostView.modifierAction(for: rightReleased), GHOSTTY_ACTION_RELEASE,
            "right shift came up; left is what is still holding .shift set")
    }

    /// Caps lock is the one modifier macOS does not side, so it has no device flag to consult and
    /// the named flag is the whole story.
    func test_capsLockUsesTheNamedFlagAlone() throws {
        XCTAssertEqual(
            GhosttyHostView.modifierAction(for: try flagsChanged(keyCode: 0x39, named: .capsLock)),
            GHOSTTY_ACTION_PRESS)
        XCTAssertEqual(
            GhosttyHostView.modifierAction(for: try flagsChanged(keyCode: 0x39)),
            GHOSTTY_ACTION_RELEASE)
    }

    /// The globe key also arrives as `flagsChanged`, and libghostty has no modifier for it.
    func test_aNonModifierKeyCodeIsNotAModifierTransition() throws {
        XCTAssertNil(GhosttyHostView.modifierAction(for: try flagsChanged(keyCode: 0x3F)))
    }

    // MARK: Translation — sided modifier bits

    /// `ghosttyMods` has to carry the side too, not just the named modifier: the kitty protocol
    /// encodes left and right as different keys, so without the sided bit every right-hand
    /// modifier arrives at the program as its left-hand counterpart.
    func test_ghosttyModsCarriesTheSideOfTheModifier() {
        let right = NSEvent.ghosttyMods(
            NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.shift.rawValue | UInt(NX_DEVICERSHIFTKEYMASK)))
        XCTAssertNotEqual(right.rawValue & GHOSTTY_MODS_SHIFT.rawValue, 0, "shift is held")
        XCTAssertNotEqual(right.rawValue & GHOSTTY_MODS_SHIFT_RIGHT.rawValue, 0, "and it is the right one")

        let left = NSEvent.ghosttyMods(
            NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.shift.rawValue | UInt(NX_DEVICELSHIFTKEYMASK)))
        XCTAssertNotEqual(left.rawValue & GHOSTTY_MODS_SHIFT.rawValue, 0, "shift is held")
        XCTAssertEqual(
            left.rawValue & GHOSTTY_MODS_SHIFT_RIGHT.rawValue, 0,
            "the left shift must not set the right-hand bit")
    }

    // MARK: Translation — mouse buttons

    /// AppKit numbers buttons in hardware order and libghostty names them by the X11 numbering a
    /// terminal reports. The two agree up to the middle button and then diverge, which is the
    /// only reason this mapping is a table rather than an offset.
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
}

/// Records what its subview declined to handle. `NSResponder`'s default `flagsChanged` and
/// `otherMouse*` implementations pass the event to `nextResponder`, so a count above zero here
/// means `GhosttyHostView` has no override for that event — which is the ZEN-308 bug exactly.
private final class RecordingResponderView: NSView {
    var flagsChangedCount = 0
    var otherMouseDownCount = 0
    var otherMouseUpCount = 0
    var otherMouseDraggedCount = 0

    override func flagsChanged(with event: NSEvent) { flagsChangedCount += 1 }
    override func otherMouseDown(with event: NSEvent) { otherMouseDownCount += 1 }
    override func otherMouseUp(with event: NSEvent) { otherMouseUpCount += 1 }
    override func otherMouseDragged(with event: NSEvent) { otherMouseDraggedCount += 1 }
}
