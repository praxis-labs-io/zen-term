import AppKit
import GhosttyKit
import XCTest

@testable import TerminalKit

final class GhosttyInputForwardingTests: XCTestCase {
    private var window: NSWindow!
    private var parent: RecordingResponderView!
    private var view: GhosttyHostView!

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false)
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

    func test_middleClickFocusesThePaneItHits() throws {
        let surface = GhosttySurface()
        let delegate = FocusRecordingDelegate()
        surface.delegate = delegate
        view.owner = surface

        window.sendEvent(try otherMouse(.otherMouseDown))

        XCTAssertEqual(delegate.focusRequests, 1, "the pane the button landed in must take focus")
    }

    func test_theEncodedKeyEventCarriesTheSide() throws {
        let event = try flagsChanged(keyCode: 0x3C, named: .shift, held: [UInt(NX_DEVICERSHIFTKEYMASK)])
        let key = event.ghosttyKeyEvent(GHOSTTY_ACTION_PRESS)
        XCTAssertNotEqual(
            key.mods.rawValue & GHOSTTY_MODS_SHIFT_RIGHT.rawValue, 0,
            "a key event built from a right-shift press has to say it was the right one")
    }

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
                GhosttyHostView.modifierTransition(for: event), GHOSTTY_ACTION_PRESS,
                "\(item.name) going down is a press")
        }
    }

    func test_releasingTheLastHeldModifierReportsARelease() throws {
        let event = try flagsChanged(keyCode: 0x38)
        XCTAssertEqual(GhosttyHostView.modifierTransition(for: event), GHOSTTY_ACTION_RELEASE)
    }

    func test_releasingOneSideWhileTheOtherIsHeldReportsARelease() throws {
        let leftReleased = try flagsChanged(
            keyCode: 0x38, named: .shift, held: [UInt(NX_DEVICERSHIFTKEYMASK)])
        XCTAssertEqual(
            GhosttyHostView.modifierTransition(for: leftReleased), GHOSTTY_ACTION_RELEASE,
            "left shift came up; right is what is still holding .shift set")

        let rightReleased = try flagsChanged(
            keyCode: 0x3C, named: .shift, held: [UInt(NX_DEVICELSHIFTKEYMASK)])
        XCTAssertEqual(
            GhosttyHostView.modifierTransition(for: rightReleased), GHOSTTY_ACTION_RELEASE,
            "right shift came up; left is what is still holding .shift set")
    }

    func test_aModifierWithNoSideInformationReadsAsAPress() throws {
        let event = try flagsChanged(keyCode: 0x38, named: .shift)
        XCTAssertEqual(
            GhosttyHostView.modifierTransition(for: event), GHOSTTY_ACTION_PRESS,
            "the named flag is the only evidence there is, and it says shift is down")
    }

    func test_capsLockUsesTheNamedFlagAlone() throws {
        XCTAssertEqual(
            GhosttyHostView.modifierTransition(for: try flagsChanged(keyCode: 0x39, named: .capsLock)),
            GHOSTTY_ACTION_PRESS)
        XCTAssertEqual(
            GhosttyHostView.modifierTransition(for: try flagsChanged(keyCode: 0x39)),
            GHOSTTY_ACTION_RELEASE)
    }

    func test_aNonModifierKeyCodeIsNotAModifierTransition() throws {
        XCTAssertNil(GhosttyHostView.modifierTransition(for: try flagsChanged(keyCode: 0x3F)))
    }

    func test_aReleaseWithNoMatchingPressIsNotForwarded() throws {
        let release = try flagsChanged(keyCode: 0x38, held: [])
        XCTAssertNil(
            view.modifierActionToForward(for: release),
            "nothing pressed shift on this surface, so libghostty must not be told it came up")

        let press = try flagsChanged(keyCode: 0x38, named: .shift, held: [UInt(NX_DEVICELSHIFTKEYMASK)])
        XCTAssertEqual(view.modifierActionToForward(for: press), GHOSTTY_ACTION_PRESS)
        XCTAssertEqual(view.modifierActionToForward(for: release), GHOSTTY_ACTION_RELEASE)
    }

    func test_aSecondPressForAModifierAlreadyDownIsNotForwarded() throws {
        let down = try flagsChanged(keyCode: 0x39, named: .capsLock)
        XCTAssertEqual(view.modifierActionToForward(for: down), GHOSTTY_ACTION_PRESS)
        XCTAssertNil(view.modifierActionToForward(for: down), "the key coming back up is not a second press")

        let up = try flagsChanged(keyCode: 0x39)
        XCTAssertEqual(view.modifierActionToForward(for: up), GHOSTTY_ACTION_RELEASE)
        XCTAssertNil(view.modifierActionToForward(for: up), "and that release does not repeat either")
    }

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

    func test_aModifierHeldIntoACompositionIsStillReleased() throws {
        let press = try flagsChanged(keyCode: 0x38, named: .shift, held: [UInt(NX_DEVICELSHIFTKEYMASK)])
        XCTAssertEqual(view.modifierActionToForward(for: press), GHOSTTY_ACTION_PRESS)

        view.markedText.mutableString.setString("か")
        let release = try flagsChanged(keyCode: 0x38)
        XCTAssertEqual(
            view.modifierActionToForward(for: release), GHOSTTY_ACTION_RELEASE,
            "libghostty is holding that press; the composition does not retire it")
    }

    func test_bothSidesOfOneModifierPairIndependently() throws {
        let left = UInt(NX_DEVICELCMDKEYMASK)
        let right = UInt(NX_DEVICERCMDKEYMASK)

        XCTAssertEqual(
            view.modifierActionToForward(
                for: try flagsChanged(keyCode: 0x37, named: .command, held: [left])),
            GHOSTTY_ACTION_PRESS)
        XCTAssertEqual(
            view.modifierActionToForward(
                for: try flagsChanged(keyCode: 0x36, named: .command, held: [left, right])),
            GHOSTTY_ACTION_PRESS,
            "right ⌘ is its own key; left being down does not make its press a duplicate")
        XCTAssertEqual(
            view.modifierActionToForward(
                for: try flagsChanged(keyCode: 0x37, named: .command, held: [right])),
            GHOSTTY_ACTION_RELEASE)
        XCTAssertEqual(
            view.modifierActionToForward(for: try flagsChanged(keyCode: 0x36)),
            GHOSTTY_ACTION_RELEASE,
            "and right still owes its own release after left's")
    }

    func test_theLedgerOwesNoReleaseForAKeyItNeverSaw() throws {
        XCTAssertFalse(
            view.retireKeyPress(for: try key(.keyUp, "h", keyCode: 0x04)),
            "nothing pressed h on this surface, so libghostty must not be told it came up")
    }

    func test_aKeyReleaseRetiresThePressItPairsWith() throws {
        view.recordKeyPress(for: try key(.keyDown, "h", keyCode: 0x04))
        view.keyUp(with: try key(.keyUp, "h", keyCode: 0x04))

        XCTAssertFalse(
            view.retireKeyPress(for: try key(.keyUp, "h", keyCode: 0x04)),
            "that release settled the press; a second one is unpaired like any other")
    }

    func test_aHeldKeyIsSettledByOneRelease() throws {
        for _ in 0..<3 { view.recordKeyPress(for: try key(.keyDown, "j", keyCode: 0x26)) }

        XCTAssertTrue(view.retireKeyPress(for: try key(.keyUp, "j", keyCode: 0x26)))
        XCTAssertFalse(view.retireKeyPress(for: try key(.keyUp, "j", keyCode: 0x26)))
    }

    func test_losingFocusForgetsModifiersAndKeepsOrdinaryKeys() throws {
        view.recordKeyPress(for: try key(.keyDown, "h", keyCode: 0x04))
        XCTAssertEqual(
            view.modifierActionToForward(
                for: try flagsChanged(keyCode: 0x38, named: .shift, held: [UInt(NX_DEVICELSHIFTKEYMASK)])),
            GHOSTTY_ACTION_PRESS)

        view.forgetHeldModifiers()

        XCTAssertTrue(
            view.retireKeyPress(for: try key(.keyUp, "h", keyCode: 0x04)),
            "libghostty only released its one pressed_key, so h is still owed its release")
        XCTAssertEqual(
            view.modifierActionToForward(
                for: try flagsChanged(keyCode: 0x38, named: .shift, held: [UInt(NX_DEVICELSHIFTKEYMASK)])),
            GHOSTTY_ACTION_PRESS,
            "and the next real shift press must not be suppressed as a duplicate")
    }

    func test_aLiveSurfaceRecordsOnlyTheKeysItActuallySent() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }

        let surface = GhosttySurface()
        surface.view.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        window.contentView?.addSubview(surface.view)
        surface.start(TerminalSurfaceConfig(command: "/bin/sh", args: ["-c", "sleep 100"]))
        defer {
            surface.view.removeFromSuperview()
            surface.terminate()
        }
        try XCTSkipIf(surface.surfacePtr == nil, "ghostty_surface_new failed")
        let host = try XCTUnwrap(surface.view as? GhosttyHostView)

        host.keyDown(with: try key(.keyDown, "\r", keyCode: 36, flags: .shift))
        XCTAssertFalse(
            host.retireKeyPress(for: try key(.keyUp, "\r", keyCode: 36, flags: .shift)),
            "the soft-newline chord sends its own text and returns, so it owes no release")

        host.keyDown(with: try key(.keyDown, "h", keyCode: 0x04))
        XCTAssertTrue(
            host.retireKeyPress(for: try key(.keyUp, "h", keyCode: 0x04)),
            "an ordinary key did reach libghostty, so its release is owed")

        host.markedText.mutableString.setString("か")
        host.keyDown(with: try key(.keyDown, "\u{1b}", keyCode: 53))
        XCTAssertFalse(
            host.retireKeyPress(for: try key(.keyUp, "\u{1b}", keyCode: 53)),
            "libghostty drops a composing key without encoding it, so no press was ever sent")
        host.markedText.mutableString.setString("")
    }

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

    func test_plainModsDoNotCarryTheSide_soLibghosttysMouseGuardStillHolds() {
        let mods = NSEvent.ghosttyMods(sided(.shift, UInt(NX_DEVICERSHIFTKEYMASK)))
        XCTAssertNotEqual(mods.rawValue & GHOSTTY_MODS_SHIFT.rawValue, 0, "shift is still reported")
        XCTAssertEqual(
            mods.rawValue & GHOSTTY_MODS_SHIFT_RIGHT.rawValue, 0,
            "the mouse path must see no sided bits")
    }

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

    private func sided(_ named: NSEvent.ModifierFlags, _ side: UInt) -> NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: named.rawValue | side)
    }

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
        _ type: NSEvent.EventType, _ characters: String, keyCode: UInt16,
        flags: NSEvent.ModifierFlags = []
    ) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
    }

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
