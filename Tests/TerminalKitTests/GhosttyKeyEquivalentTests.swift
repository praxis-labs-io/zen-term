import AppKit
import XCTest

@testable import TerminalKit

final class GhosttyKeyEquivalentTests: XCTestCase {
    private var window: NSWindow!
    private var view: GhosttyHostView!

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        view = GhosttyHostView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        window.contentView?.addSubview(view)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
    }

    override func tearDown() {
        window.close()
        window = nil
        view = nil
        super.tearDown()
    }

    func test_theSurfaceTakesCtrlReturn_ratherThanLeavingItToTheContextMenuEquivalent() throws {
        XCTAssertTrue(window.firstResponder === view, "the surface has to be first responder")

        XCTAssertTrue(
            window.performKeyEquivalent(with: try key("\r", keyCode: 36, flags: .control)),
            "Ctrl-Return declined here goes to the default context-menu equivalent instead")
    }

    func test_anUnfocusedSurfaceDeclinesKeyEquivalents() throws {
        window.makeFirstResponder(nil)

        XCTAssertFalse(
            window.performKeyEquivalent(with: try key("/", keyCode: 44, flags: .control)),
            "this pane does not have the keyboard, so it must not claim the key")
    }

    func test_aControlKeyIsDeclinedOnceAndTakenOnTheWayBack() throws {
        let event = try controlE()

        XCTAssertFalse(
            window.performKeyEquivalent(with: event),
            "the first pass has to let the rest of AppKit have a say")
        XCTAssertTrue(
            window.performKeyEquivalent(with: event),
            "the same event coming back is one nothing else claimed, so it is the pane's")
    }

    func test_onlyThePendingEventIsSentBackThroughTheEventSystem() throws {
        let event = try controlE()
        XCTAssertNil(view.eventToRedispatch(event), "nothing is pending, so nothing goes back")

        XCTAssertNil(view.keyEquivalentEvent(for: event), "the first pass records and declines")

        XCTAssertTrue(view.eventToRedispatch(event) === event, "that one is owed a second pass")
        XCTAssertNil(
            view.eventToRedispatch(try controlE(timestamp: 99)),
            "a selector fired by some other keystroke must not resend it")
        XCTAssertNil(view.eventToRedispatch(nil))
    }

    func test_aClaimedKeyEquivalentReachesKeyDown() throws {
        let liveWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false)
        liveWindow.isReleasedWhenClosed = false
        defer { liveWindow.close() }

        let surface = GhosttySurface()
        surface.view.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        liveWindow.contentView?.addSubview(surface.view)
        surface.start(TerminalSurfaceConfig(command: "/bin/sh", args: ["-c", "sleep 100"]))
        defer {
            surface.view.removeFromSuperview()
            surface.terminate()
        }
        try XCTSkipIf(surface.surfacePtr == nil, "ghostty_surface_new failed")
        let host = try XCTUnwrap(surface.view as? GhosttyHostView)
        liveWindow.makeFirstResponder(host)

        let event = try key("\r", keyCode: 36, flags: .control)
        XCTAssertTrue(liveWindow.performKeyEquivalent(with: event))

        XCTAssertTrue(
            host.retireKeyPress(for: event),
            "the ledger owes a release, so keyDown ran and libghostty was told the key went down")

        host.lastPerformKeyEvent = 99
        host.keyDown(with: try key("h", keyCode: 0x04))
        XCTAssertNil(host.lastPerformKeyEvent)
    }

    func test_ctrlReturnIsPassedThroughVerbatim() throws {
        let event = try key("\r", keyCode: 36, flags: .control)
        let result = try XCTUnwrap(view.keyEquivalentEvent(for: event))
        XCTAssertEqual(result.characters, "\r")
        XCTAssertEqual(result.keyCode, 36)
    }

    func test_aReturnWithoutControlIsLeftAlone() throws {
        XCTAssertNil(
            view.keyEquivalentEvent(for: try key("\r", keyCode: 36)),
            "plain Return belongs to the responder chain; only the control chord is claimed here")
    }

    func test_ctrlSlashIsRewrittenToUnderscore() throws {
        let event = try key("/", keyCode: 44, flags: .control)
        let result = try XCTUnwrap(view.keyEquivalentEvent(for: event))
        XCTAssertEqual(result.characters, "_")
        XCTAssertEqual(result.charactersIgnoringModifiers, "_", "both, or the encoder reads a slash")
        XCTAssertEqual(result.keyCode, 44)
    }

    func test_slashWithAnyOtherModifierIsLeftAlone() throws {
        for extra: NSEvent.ModifierFlags in [.shift, .command, .option] {
            XCTAssertNil(
                view.keyEquivalentEvent(for: try key("/", keyCode: 44, flags: [.control, extra])),
                "bare Ctrl-/ is the one that beeps")
        }
    }

    func test_aZeroStampedEventIsNeverRecorded() throws {
        let event = try key("e", keyCode: 0x0E, flags: .command, timestamp: 0)
        XCTAssertNil(view.keyEquivalentEvent(for: event))
        XCTAssertNil(view.lastPerformKeyEvent)
    }

    func test_anUnmoddedKeyClearsTheRecordedTimestamp() throws {
        let event = try controlE()
        XCTAssertNil(view.keyEquivalentEvent(for: event), "the first pass records and declines")

        XCTAssertNil(view.keyEquivalentEvent(for: try key("a", keyCode: 0x00, timestamp: 13)))

        XCTAssertNil(
            view.keyEquivalentEvent(for: event),
            "a plain keystroke landed in between, so this is a new chord, not one coming back")
    }

    func test_aDifferentTimestampStartsOver() throws {
        XCTAssertNil(view.keyEquivalentEvent(for: try controlE(timestamp: 1)))
        XCTAssertNil(
            view.keyEquivalentEvent(for: try controlE(timestamp: 2)),
            "a second, different keystroke is declined once like any other")

        let result = try XCTUnwrap(view.keyEquivalentEvent(for: try controlE(timestamp: 2)))
        XCTAssertEqual(result.characters, "\u{05}", "the claimed event carries the control code")
    }

    private func controlE(timestamp: TimeInterval = 12.5) throws -> NSEvent {
        try key(
            "\u{05}", ignoringModifiers: "e", keyCode: 0x0E, flags: .control, timestamp: timestamp)
    }

    private func key(
        _ characters: String, ignoringModifiers: String? = nil, keyCode: UInt16,
        flags: NSEvent.ModifierFlags = [], timestamp: TimeInterval = 12.5
    ) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: timestamp,
                windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: ignoringModifiers ?? characters, isARepeat: false,
                keyCode: keyCode))
    }
}
