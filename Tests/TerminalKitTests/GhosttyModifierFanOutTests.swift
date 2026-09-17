import AppKit
import GhosttyKit
import XCTest

@testable import TerminalKit

final class GhosttyModifierFanOutTests: XCTestCase {
    private var window: NSWindow!
    private var focused: GhosttySurface!
    private var unfocused: GhosttySurface!

    private var focusedHost: GhosttyHostView { host(of: focused) }
    private var unfocusedHost: GhosttyHostView { host(of: unfocused) }

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        focused = GhosttySurface()
        unfocused = GhosttySurface()
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        focused.view.frame = NSRect(x: 0, y: 0, width: 200, height: 300)
        unfocused.view.frame = NSRect(x: 200, y: 0, width: 200, height: 300)
        content.addSubview(focused.view)
        content.addSubview(unfocused.view)
        window.contentView = content
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(focused.view)
    }

    override func tearDown() {
        focused.terminate()
        unfocused.terminate()
        window.close()
        window = nil
        focused = nil
        unfocused = nil
        super.tearDown()
    }

    func test_theFanOutReachesAPaneTheResponderChainSkipped() throws {
        XCTAssertTrue(window.firstResponder === focused.view, "the split's focus has to be real")

        let press = try commandDown()
        window.sendEvent(press)

        XCTAssertNil(
            unfocusedHost.modifierActionToForward(for: try commandUp()),
            "the responder chain reaches the focused pane only, so the other pane holds no ⌘ yet")

        unfocused.modifiersDidChange(press)

        XCTAssertEqual(
            unfocusedHost.modifierActionToForward(for: try commandUp()), GHOSTTY_ACTION_RELEASE,
            "the fan-out has to leave the unfocused pane holding ⌘, or libghostty never highlights "
                + "a link under the pointer and never clears the mods on release")
    }

    func test_theFanOutNeverDoubleReportsToTheFocusedPane() throws {
        let press = try commandDown()
        window.sendEvent(press)

        focused.modifiersDidChange(press)

        XCTAssertNil(
            focusedHost.modifierActionToForward(for: press),
            "the focused pane took ⌘ through the responder chain, so the fan-out must find it "
                + "already reported; a second press reaches the program as a phantom keystroke")
    }

    func test_theFanOutPairsItsOwnRelease() throws {
        let press = try commandDown()
        unfocused.modifiersDidChange(press)
        unfocused.modifiersDidChange(try commandUp())

        XCTAssertEqual(
            unfocusedHost.modifierActionToForward(for: try commandUp()), nil,
            "a release the fan-out already sent must not send a second, unpaired one")
    }

    private func host(of surface: GhosttySurface) -> GhosttyHostView {
        guard let host = surface.view as? GhosttyHostView else {
            fatalError("GhosttySurface stopped hosting a GhosttyHostView")
        }
        return host
    }

    private func commandDown() throws -> NSEvent {
        try flagsChanged(
            keyCode: 0x37, named: .command, held: [UInt(NX_DEVICELCMDKEYMASK)])
    }

    private func commandUp() throws -> NSEvent {
        try flagsChanged(keyCode: 0x37)
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
}
