import AppKit
import XCTest

@testable import ZenTerm

final class ControlViewTests: WindowTestCase {
    private var window: NSWindow!

    override func setUpWithError() throws {
        try super.setUpWithError()
        Motion.isReduceMotionEnabled = { false }
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.borderless], backing: .buffered, defer: false)
    }

    private func mount(_ view: NSView) -> NSView {
        view.translatesAutoresizingMaskIntoConstraints = true
        window.contentView?.addSubview(view)
        view.frame = NSRect(x: 20, y: 20, width: 160, height: ChromeMetrics.Height.control)
        return view
    }

    private func crossing(_ type: NSEvent.EventType) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.enterExitEvent(
                with: type, location: NSPoint(x: 30, y: 30), modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
    }

    private func key(_ code: UInt16, _ characters: String, shift: Bool = false) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: shift ? .shift : [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
    }

    private var hoverFilledControls: [(String, NSView)] {
        [
            ("AppButton", AppButton(title: "Add", variant: .secondary)),
            ("IconButton", IconButton(symbol: "plus", accessibilityLabel: "New tab") {}),
            ("SidebarJumpRow", SidebarJumpRow(tooltip: "Jump") {}),
            ("NavRow", NavRow(title: "General") {}),
            ("ListRow", ListRow(ListRow.Content(title: "Rename")) {}),
            ("KeybindChip", KeybindChip()),
            ("WorkspaceTabChip", WorkspaceTabChip()),
            ("DrawerRail", DrawerRail(region: .bottom)),
        ]
    }

    func test_hoverEnterAndExit_easeTheFillInAndOut() throws {
        let hover = Theme.current.chrome.fill(.hover).cgColor
        for (name, control) in hoverFilledControls {
            let view = mount(control)
            view.layer?.removeAllAnimations()

            view.mouseEntered(with: try crossing(.mouseEntered))

            XCTAssertEqual(view.layer?.backgroundColor, hover, "\(name) shows no hover fill")
            XCTAssertNotNil(view.layer?.animation(forKey: "motion.backgroundColor"), "\(name) snaps its fill in")

            view.layer?.removeAllAnimations()
            view.mouseExited(with: try crossing(.mouseExited))

            XCTAssertNotEqual(view.layer?.backgroundColor, hover, "\(name) keeps its hover fill")
            XCTAssertNotNil(view.layer?.animation(forKey: "motion.backgroundColor"), "\(name) snaps its fill out")
        }
    }

    func test_aHiddenControl_dropsItsHover() throws {
        for (name, control) in hoverFilledControls {
            let view = mount(control)
            view.mouseEntered(with: try crossing(.mouseEntered))

            view.isHidden = true
            view.isHidden = false

            XCTAssertNotEqual(
                view.layer?.backgroundColor, Theme.current.chrome.fill(.hover).cgColor,
                "\(name) comes back hovered after hiding under a still pointer")
        }
    }

    func test_regionCommandField_revealsItsCornerButtonOnHoverOnly() throws {
        let field = RegionCommandField(region: .main)
        _ = mount(field)
        XCTAssertFalse(field.isCornerButtonVisibleForTesting)

        field.mouseEntered(with: try crossing(.mouseEntered))
        XCTAssertTrue(field.isCornerButtonVisibleForTesting)

        field.mouseExited(with: try crossing(.mouseExited))
        XCTAssertFalse(field.isCornerButtonVisibleForTesting)
    }

    func test_aFocusedIconButton_ringsInTheFocusRing_untilFocusLeaves() {
        let button = IconButton(symbol: "checkmark", accessibilityLabel: "Save") {}
        button.isKeyboardFocusable = true
        _ = mount(button)

        XCTAssertTrue(window.makeFirstResponder(button))
        XCTAssertEqual(button.layer?.borderColor, Theme.current.chrome.focusRing.cgColor)
        XCTAssertEqual(button.layer?.borderWidth, ChromeMetrics.Border.width)

        window.makeFirstResponder(nil)
        XCTAssertEqual(button.layer?.borderColor?.alpha, 0, "the ring stays after focus leaves")
    }

    func test_aFocusedIconButton_activatesOnReturnAndSpace() throws {
        var fired = 0
        let button = IconButton(symbol: "checkmark", accessibilityLabel: "Save") { fired += 1 }
        button.isKeyboardFocusable = true
        _ = mount(button)
        XCTAssertTrue(window.makeFirstResponder(button))

        button.keyDown(with: try key(36, "\r"))
        XCTAssertEqual(fired, 1, "Return did not activate")
        button.keyDown(with: try key(49, " "))
        XCTAssertEqual(fired, 2, "Space did not activate")
    }

    func test_tabAndShiftTab_handFocusOnThroughTheButtonsCallbacks() throws {
        let save = IconButton(symbol: "checkmark", accessibilityLabel: "Save") {}
        let cancel = IconButton(symbol: "xmark", accessibilityLabel: "Cancel") {}
        for (index, button) in [save, cancel].enumerated() {
            button.isKeyboardFocusable = true
            _ = mount(button)
            button.frame.origin.x = 20 + CGFloat(index) * 60
        }
        save.onTab = { [unowned self] in window.makeFirstResponder(cancel) }
        cancel.onBacktab = { [unowned self] in window.makeFirstResponder(save) }
        XCTAssertTrue(window.makeFirstResponder(save))

        save.keyDown(with: try key(48, "\t"))
        XCTAssertTrue(window.firstResponder === cancel, "Tab did not reach the next button")
        XCTAssertEqual(cancel.layer?.borderColor, Theme.current.chrome.focusRing.cgColor)
        XCTAssertEqual(save.layer?.borderColor?.alpha, 0)

        cancel.keyDown(with: try key(48, "\u{19}", shift: true))
        XCTAssertTrue(window.firstResponder === save, "Shift-Tab did not come back")
    }
}
