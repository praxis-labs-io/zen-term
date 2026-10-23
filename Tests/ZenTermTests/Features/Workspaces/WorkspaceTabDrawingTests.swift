import AppKit
import XCTest

@testable import ZenTerm

final class WorkspaceTabDrawingTests: WindowTestCase {
    private var window: NSWindow?
    private var drawing: WorkspaceTabDrawing!
    private var form = WorkspaceForm(editing: nil)
    private var closed: [Workspace.Region] = []
    private var exits: [String] = []

    override func tearDown() {
        window = nil
        drawing = nil
        super.tearDown()
    }

    private func mount(_ tab: Workspace.Tab, focus: Workspace.Region = .main) {
        form = WorkspaceForm(
            editing: Workspace(
                title: "W", path: URL(fileURLWithPath: "/tmp"), tabs: [tab],
                focus: Workspace.LaunchFocus(tab: 0, region: focus), env: [:]))
        let drawing = WorkspaceTabDrawing()
        drawing.onCommandChanged = { [unowned self] region, text in
            form.setCommand(text, in: region, ofTab: 0)
            rerender()
        }
        drawing.onDrawerClosed = { [unowned self] region in
            closed.append(region)
            _ = form.repairLaunchFocus()
            rerender()
        }
        drawing.onOpenFocused = { [unowned self] region in
            form.setLaunchFocus(region, inTab: 0)
            rerender()
        }
        drawing.onExitUp = { [unowned self] in exits.append("up") }
        drawing.onExitDown = { [unowned self] in exits.append("down") }
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 300), styleMask: [.borderless], backing: .buffered,
            defer: false)
        let content = win.contentView!
        content.addSubview(drawing)
        NSLayoutConstraint.activate([
            drawing.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
            drawing.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),
            drawing.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
        ])
        self.drawing = drawing
        window = win
        win.makeKeyAndOrderFront(nil)
        rerender()
    }

    private func rerender() {
        drawing.render(
            tab: form.tabs[0], index: 0,
            opensFocusedIn: form.launchFocus.tab == 0 ? form.launchFocus.region : nil)
        window?.contentView?.layoutSubtreeIfNeeded()
    }

    private func mouseDown(on view: NSView) throws -> NSEvent {
        let point = view.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        return try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: window!.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    private func arrow(_ code: UInt16, _ scalar: Int) throws -> NSEvent {
        let text = String(UnicodeScalar(scalar)!)
        return try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [.function, .numericPad], timestamp: 0,
                windowNumber: window!.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text,
                isARepeat: false, keyCode: code))
    }

    private func right() throws -> NSEvent { try arrow(124, NSRightArrowFunctionKey) }
    private func left() throws -> NSEvent { try arrow(123, NSLeftArrowFunctionKey) }
    private func down() throws -> NSEvent { try arrow(125, NSDownArrowFunctionKey) }
    private func up() throws -> NSEvent { try arrow(126, NSUpArrowFunctionKey) }

    private var editor: NSTextView? { window?.firstResponder as? NSTextView }

    private func isFocused(_ region: Workspace.Region) -> Bool {
        guard let field = drawing.region(region)?.field else { return false }
        return KeyboardFocus.isFocused(field, in: window)
    }

    func test_emptyDrawers_areRails_andSetOnesAreFields() {
        mount(Workspace.Tab(main: "nvim", bottom: "bin/check"))

        XCTAssertNotNil(drawing.rail(.right)?.superview, "an empty right drawer stays closed")
        XCTAssertNil(drawing.region(.right)?.superview)
        XCTAssertNotNil(drawing.region(.bottom)?.superview)
        XCTAssertNil(drawing.rail(.bottom)?.superview)
        XCTAssertEqual(drawing.region(.bottom)?.text, "bin/check")
        XCTAssertEqual(drawing.rail(.right)?.tooltipLabelForTesting, "Add a right drawer command")
        XCTAssertEqual(drawing.rail(.bottom)?.tooltipLabelForTesting, "Add a bottom drawer command")
    }

    func test_anEmptyMainPane_saysItRunsAShell() {
        mount(Workspace.Tab())

        XCTAssertEqual(drawing.region(.main)?.field.placeholderAttributedString?.string, "shell")
    }

    func test_clickingARail_opensItIntoAFocusedField() throws {
        mount(Workspace.Tab())
        let rail = try XCTUnwrap(drawing.rail(.right))

        rail.mouseDown(with: try mouseDown(on: rail))

        XCTAssertNil(rail.superview)
        XCTAssertTrue(isFocused(.right))
    }

    func test_typingInAnOpenedDrawer_setsItsCommand() throws {
        mount(Workspace.Tab())
        drawing.rail(.bottom)?.onOpen?()

        try XCTUnwrap(editor).insertText("npm run dev", replacementRange: NSRange(location: NSNotFound, length: 0))

        XCTAssertEqual(form.tabs[0].bottom, "npm run dev")
    }

    func test_leavingAnOpenedDrawerEmpty_closesItBackToARail() throws {
        mount(Workspace.Tab())
        drawing.rail(.right)?.onOpen?()
        XCTAssertTrue(isFocused(.right))

        try XCTUnwrap(editor).keyDown(with: try left())
        rerender()

        XCTAssertTrue(isFocused(.main))
        XCTAssertEqual(closed, [.right])
        XCTAssertNotNil(drawing.rail(.right)?.superview)
    }

    func test_emptyingTheDrawerThatOpensFocused_handsFocusToTheMainPane() throws {
        mount(Workspace.Tab(main: "nvim", right: "claude"), focus: .right)
        XCTAssertTrue(try XCTUnwrap(drawing.region(.right)).isMarkerVisibleForTesting)
        drawing.focus(.right)
        let field = try XCTUnwrap(editor)

        field.selectAll(nil)
        field.deleteBackward(nil)
        window?.makeFirstResponder(drawing.region(.main)?.field)
        rerender()

        XCTAssertNil(form.tabs[0].right)
        XCTAssertEqual(form.launchFocus, .start)
        XCTAssertTrue(try XCTUnwrap(drawing.region(.main)).isMarkerVisibleForTesting)
    }

    func test_rightArrowAtTheEndOfMain_movesToTheRightDrawer() throws {
        mount(Workspace.Tab(main: "nvim", right: "claude"))
        drawing.focus(.main)
        let field = try XCTUnwrap(editor)
        field.setSelectedRange(NSRange(location: 0, length: 0))

        field.keyDown(with: try right())
        XCTAssertTrue(isFocused(.main), "mid-text, Right moves the caret")

        field.setSelectedRange(NSRange(location: 4, length: 0))
        field.keyDown(with: try right())
        XCTAssertTrue(isFocused(.right))
    }

    func test_rightArrowOnAnEmptyMain_reachesTheRightRail() throws {
        mount(Workspace.Tab())
        drawing.focus(.main)

        try XCTUnwrap(editor).keyDown(with: try right())

        XCTAssertIdentical(window?.firstResponder, drawing.rail(.right))
    }

    func test_upAndDown_moveBetweenMainAndBottom_andLeaveTheDrawingAtItsEdges() throws {
        mount(Workspace.Tab(main: "nvim", bottom: "shell"))
        drawing.focus(.main)

        try XCTUnwrap(editor).keyDown(with: try down())
        XCTAssertTrue(isFocused(.bottom))

        try XCTUnwrap(editor).keyDown(with: try up())
        XCTAssertTrue(isFocused(.main))

        try XCTUnwrap(editor).keyDown(with: try up())
        XCTAssertEqual(exits, ["up"])

        drawing.focus(.bottom)
        try XCTUnwrap(editor).keyDown(with: try down())
        XCTAssertEqual(exits, ["up", "down"])
    }

    func test_aRail_answersArrowsToo() throws {
        mount(Workspace.Tab())
        let rail = try XCTUnwrap(drawing.rail(.right))
        window?.makeFirstResponder(rail)

        rail.keyDown(with: try left())

        XCTAssertTrue(isFocused(.main))
    }

    func test_theCornerButton_movesTheLaunchFocusThere() throws {
        mount(Workspace.Tab(main: "nvim", right: "claude"))
        let right = try XCTUnwrap(drawing.region(.right))
        drawing.focus(.right)
        XCTAssertTrue(right.isCornerButtonVisibleForTesting)

        right.cornerButtonForTesting.mouseDown(with: try mouseDown(on: right.cornerButtonForTesting))

        XCTAssertEqual(form.launchFocus, Workspace.LaunchFocus(tab: 0, region: .right))
        XCTAssertTrue(right.isMarkerVisibleForTesting)
        XCTAssertFalse(try XCTUnwrap(drawing.region(.main)).isMarkerVisibleForTesting)
        XCTAssertEqual(right.cornerButtonForTesting.tooltipLabelForTesting, "Open with focus here")
        XCTAssertEqual(right.cornerButtonForTesting.tooltipShortcutForTesting, "⌘L")
    }

    func test_openFocusedFromTheKeyboard_takesTheFocusedRegion_butNeverARail() throws {
        mount(Workspace.Tab(main: "nvim", bottom: "shell"))
        drawing.focus(.bottom)

        XCTAssertTrue(drawing.openFocusedAtFocusedRegion())
        XCTAssertEqual(form.launchFocus.region, .bottom)

        window?.makeFirstResponder(drawing.rail(.right))
        XCTAssertFalse(drawing.openFocusedAtFocusedRegion())
        XCTAssertEqual(form.launchFocus.region, .bottom)
    }

    func test_switchingTabsWhileAFieldIsFocused_showsTheNewTabsCommand() throws {
        mount(Workspace.Tab(main: "nvim"))
        drawing.focus(.main)

        drawing.render(tab: Workspace.Tab(main: "lazygit"), index: 1, opensFocusedIn: nil)

        XCTAssertEqual(drawing.region(.main)?.text, "lazygit")
        XCTAssertEqual(try XCTUnwrap(editor).string, "lazygit")
    }
}
