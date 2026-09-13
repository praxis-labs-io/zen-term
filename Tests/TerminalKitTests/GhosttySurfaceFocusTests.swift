import AppKit
import GhosttyKit
import XCTest

@testable import TerminalKit

final class GhosttySurfaceFocusTests: XCTestCase {
    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    private func postAppActive(_ active: Bool) {
        NotificationCenter.default.post(
            name: active
                ? NSApplication.didBecomeActiveNotification
                : NSApplication.didResignActiveNotification,
            object: NSApp)
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 1)
    }

    func test_appDeactivationUnfocusesAFocusedPane() {
        let surface = GhosttySurface()
        surface.setFocused(true)
        XCTAssertTrue(surface.lastFocused, "a focused pane in an active app is focused")

        postAppActive(false)
        XCTAssertFalse(surface.lastFocused, "switching apps has to unfocus the surface")

        postAppActive(true)
        XCTAssertTrue(surface.lastFocused, "coming back restores the pane that had focus")
    }

    func test_appActivationDoesNotFocusAnUnfocusedPane() {
        let surface = GhosttySurface()
        surface.setFocused(false)

        postAppActive(false)
        XCTAssertFalse(surface.lastFocused)

        postAppActive(true)
        XCTAssertFalse(surface.lastFocused, "an unfocused pane stays unfocused when the app returns")
    }

    func test_focusingAPaneWhileTheAppIsInactiveKeepsTheSurfaceUnfocused() {
        let surface = GhosttySurface()
        postAppActive(false)

        surface.setFocused(true)
        XCTAssertFalse(surface.lastFocused, "pane focus alone can't focus a surface in a background app")

        postAppActive(true)
        XCTAssertTrue(surface.lastFocused, "and it takes effect once the app is frontmost")
    }

    func test_appDeactivationForgetsWhatTheSurfaceSaidWasHeld() throws {
        let surface = GhosttySurface()
        surface.setFocused(true)
        let host = try XCTUnwrap(surface.view as? GhosttyHostView)
        XCTAssertEqual(host.modifierActionToForward(for: try leftShiftPress()), GHOSTTY_ACTION_PRESS)

        postAppActive(false)
        postAppActive(true)

        XCTAssertEqual(
            host.modifierActionToForward(for: try leftShiftPress()), GHOSTTY_ACTION_PRESS,
            "libghostty released that shift when the app went away, so pressing it again is a press")
    }

    func test_aRepeatedUnfocusedSyncKeepsTheLedger() throws {
        let surface = GhosttySurface()
        let host = try XCTUnwrap(surface.view as? GhosttyHostView)
        surface.setFocused(false)

        XCTAssertEqual(host.modifierActionToForward(for: try leftShiftPress()), GHOSTTY_ACTION_PRESS)
        surface.setFocused(false)

        XCTAssertEqual(
            host.modifierActionToForward(for: try leftShiftRelease()), GHOSTTY_ACTION_RELEASE,
            "libghostty deduped that sync and still holds shift, so its release is still owed")
    }

    private func leftShiftPress() throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.keyEvent(
                with: .flagsChanged, location: .zero,
                modifierFlags: NSEvent.ModifierFlags(
                    rawValue: NSEvent.ModifierFlags.shift.rawValue | UInt(NX_DEVICELSHIFTKEYMASK)),
                timestamp: 0, windowNumber: 0, context: nil, characters: "",
                charactersIgnoringModifiers: "", isARepeat: false, keyCode: 0x38))
    }

    private func leftShiftRelease() throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.keyEvent(
                with: .flagsChanged, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, characters: "",
                charactersIgnoringModifiers: "", isARepeat: false, keyCode: 0x38))
    }

    func test_terminateStopsTrackingAppActivation() {
        let surface = GhosttySurface()
        surface.setFocused(true)
        surface.terminate()

        postAppActive(false)
        XCTAssertTrue(surface.lastFocused, "a terminated surface no longer follows activation")
    }
}
