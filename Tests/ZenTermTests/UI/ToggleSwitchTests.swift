import AppKit
import XCTest

@testable import ZenTerm

final class ToggleSwitchTests: WindowTestCase {
    private var window: NSWindow!

    override func setUpWithError() throws {
        try super.setUpWithError()
        Motion.isReduceMotionEnabled = { false }
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 120),
            styleMask: [.borderless], backing: .buffered, defer: false)
    }

    private func mount(isOn: Bool = false, onChange: @escaping (Bool) -> Void = { _ in }) -> ToggleSwitch {
        let control = ToggleSwitch(isOn: isOn, onChange: onChange)
        window.contentView?.addSubview(control)
        NSLayoutConstraint.activate([
            control.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 20),
            control.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 20),
        ])
        window.contentView?.layoutSubtreeIfNeeded()
        return control
    }

    private func mouse(_ type: NSEvent.EventType, at point: NSPoint) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    private func center(of control: ToggleSwitch) -> NSPoint {
        control.convert(NSPoint(x: control.bounds.midX, y: control.bounds.midY), to: nil)
    }

    private func press(at down: NSPoint, releaseAt up: NSPoint) throws {
        let target = try XCTUnwrap(window.contentView?.hitTest(down), "nothing takes the click")
        target.mouseDown(with: try mouse(.leftMouseDown, at: down))
        target.mouseUp(with: try mouse(.leftMouseUp, at: up))
    }

    private func click(_ control: ToggleSwitch) throws {
        try press(at: center(of: control), releaseAt: center(of: control))
    }

    private func key(_ code: UInt16, _ characters: String, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
    }

    func test_click_flipsOnThenOff_andReportsEachChange() throws {
        var changes: [Bool] = []
        let control = mount { changes.append($0) }

        try click(control)
        XCTAssertTrue(control.isOn)
        XCTAssertTrue(control.isKnobSlidingForTesting, "the knob jumps instead of sliding")

        try click(control)
        XCTAssertFalse(control.isOn)
        XCTAssertEqual(changes, [true, false])
    }

    func test_click_movesTheKnobToTheOnEnd() throws {
        let control = mount()
        let offCenter = control.knobCenterForTesting

        try click(control)

        XCTAssertGreaterThan(control.knobCenterForTesting.x, offCenter.x)
        XCTAssertEqual(control.trackFillForTesting, Theme.current.chrome.accent.nsColor.cgColor)
        XCTAssertEqual(control.knobFillForTesting, Theme.current.chrome.onAccent.nsColor.cgColor)
    }

    func test_offTrack_isTheActiveFill() {
        let control = mount()

        XCTAssertEqual(control.trackFillForTesting, Theme.current.chrome.fill(.active).cgColor)
    }

    func test_releasingOutside_doesNotFlip() throws {
        var changes: [Bool] = []
        let control = mount { changes.append($0) }
        let outside = control.convert(NSPoint(x: control.bounds.maxX + 40, y: control.bounds.midY), to: nil)

        try press(at: center(of: control), releaseAt: outside)

        XCTAssertFalse(control.isOn)
        XCTAssertEqual(changes, [])
    }

    func test_disabled_ignoresClicksAndKeys() throws {
        var changes: [Bool] = []
        let control = mount { changes.append($0) }
        control.isEnabled = false

        try click(control)
        control.keyDown(with: try key(49, " "))

        XCTAssertFalse(control.isOn)
        XCTAssertEqual(changes, [])
        XCTAssertFalse(control.acceptsFirstResponder, "a disabled switch takes focus")
    }

    func test_spaceAndReturn_flipTheFocusedSwitch() throws {
        var changes: [Bool] = []
        let control = mount { changes.append($0) }
        XCTAssertTrue(window.makeFirstResponder(control))

        window.sendEvent(try key(49, " "))
        window.sendEvent(try key(36, "\r"))

        XCTAssertEqual(changes, [true, false])
    }

    func test_commandSpace_doesNotFlip() throws {
        var changes: [Bool] = []
        let control = mount { changes.append($0) }
        XCTAssertTrue(window.makeFirstResponder(control))

        window.sendEvent(try key(49, " ", flags: .command))

        XCTAssertEqual(changes, [])
    }

    func test_arrows_reachTheirCallbacks_withoutFlipping() throws {
        var calls: [String] = []
        let control = mount { _ in calls.append("flip") }
        control.onArrowUp = { calls.append("up") }
        control.onArrowDown = { calls.append("down") }
        control.onArrowLeft = { calls.append("left") }
        XCTAssertTrue(window.makeFirstResponder(control))

        for code: UInt16 in [126, 125, 123] {
            window.sendEvent(try key(code, "", flags: [.function, .numericPad]))
        }

        XCTAssertEqual(calls, ["up", "down", "left"])
        XCTAssertFalse(control.isOn)
    }

    func test_accessibility_isASwitchWhoseValueFollowsTheState() throws {
        let control = mount()

        XCTAssertEqual(control.accessibilityRole(), .checkBox)
        XCTAssertEqual(control.accessibilitySubrole(), .switch)
        XCTAssertEqual(control.accessibilityValue() as? NSNumber, 0)

        try click(control)
        XCTAssertEqual(control.accessibilityValue() as? NSNumber, 1)
    }

    func test_accessibilityPress_flips_unlessDisabled() {
        var changes: [Bool] = []
        let control = mount { changes.append($0) }

        XCTAssertTrue(control.accessibilityPerformPress())
        control.isEnabled = false
        XCTAssertFalse(control.accessibilityPerformPress())

        XCTAssertEqual(changes, [true])
        XCTAssertTrue(control.isOn)
    }

    func test_setOn_movesWithoutReporting() {
        var changes: [Bool] = []
        let control = mount { changes.append($0) }

        control.setOn(true)

        XCTAssertTrue(control.isOn)
        XCTAssertEqual(changes, [])
        XCTAssertFalse(control.isKnobSlidingForTesting)
        XCTAssertEqual(control.accessibilityValue() as? NSNumber, 1)
    }

    func test_focus_showsTheRing() {
        let control = mount()

        XCTAssertTrue(window.makeFirstResponder(control))

        XCTAssertEqual(control.layer?.borderColor, Theme.current.chrome.focusRing.cgColor)
    }
}
