import AppKit
import GhosttyKit
import XCTest

@testable import TerminalKit

final class GhosttyModifierFanOutTests: XCTestCase {
    // xctest runs `.prohibited`, so a real window never reads as key.
    private final class KeyWindow: NSWindow {
        override var isKeyWindow: Bool { true }
    }

    private var window: NSWindow!
    private var content: NSView!
    private var focused: GhosttySurface!
    private var unfocused: GhosttySurface!
    private var extraWindows: [NSWindow] = []

    private var focusedHost: GhosttyHostView { host(of: focused) }
    private var unfocusedHost: GhosttyHostView { host(of: unfocused) }

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared

        window = KeyWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        focused = GhosttySurface()
        unfocused = GhosttySurface()
        content = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        focused.view.frame = NSRect(x: 0, y: 0, width: 200, height: 300)
        unfocused.view.frame = NSRect(x: 200, y: 0, width: 200, height: 300)
        content.addSubview(focused.view)
        content.addSubview(unfocused.view)
        window.contentView = content
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(focused.view)
    }

    override func tearDown() {
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        focused.terminate()
        unfocused.terminate()
        window.close()
        extraWindows.forEach { $0.close() }
        extraWindows = []
        window = nil
        content = nil
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
        unfocused.modifiersDidChange(try commandDown())
        unfocused.modifiersDidChange(try commandUp())

        XCTAssertNil(
            unfocusedHost.modifierActionToForward(for: try commandUp()),
            "a release the fan-out already sent must not send a second, unpaired one")
    }

    func test_aPaneThatLeftTheScreenStillTakesTheReleaseItIsOwed() throws {
        unfocused.modifiersDidChange(try commandDown())

        unfocused.view.removeFromSuperview()
        unfocused.modifiersDidChange(try commandUp())
        content.addSubview(unfocused.view)

        XCTAssertEqual(
            unfocusedHost.modifierActionToForward(for: try commandDown()), GHOSTTY_ACTION_PRESS,
            "a tab switched away while ⌘ is held must still settle ⌘, or it holds a stale ⌘ and "
                + "drops the next press as a duplicate")
    }

    func test_aPaneOffScreenTakesNoPress() throws {
        unfocused.view.removeFromSuperview()

        unfocused.modifiersDidChange(try commandDown())

        XCTAssertNil(
            unfocusedHost.modifierActionToForward(for: try commandUp()),
            "a closed float, a background tab or a collapsed drawer is off screen, so a ⌘ press "
                + "must not reach its program")
    }

    func test_aPaneInAWindowThatIsNotKeyTakesNoPress() throws {
        let background = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false)
        background.isReleasedWhenClosed = false
        extraWindows.append(background)
        background.contentView = unfocused.view

        unfocused.modifiersDidChange(try commandDown())

        XCTAssertNil(
            unfocusedHost.modifierActionToForward(for: try commandUp()),
            "presses belong to the key window; another window hears only the releases it is owed")
    }

    func test_resigningActiveForgetsEveryPanesHeldModifiers() throws {
        unfocused.setFocused(false)
        unfocused.modifiersDidChange(try commandDown())

        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: nil)

        XCTAssertEqual(
            unfocusedHost.modifierActionToForward(for: try commandDown()), GHOSTTY_ACTION_PRESS,
            "⌘-Tab away with ⌘ held sends the release to another app, so an unfocused pane has to "
                + "forget ⌘ too or it drops the next press as a duplicate")
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
