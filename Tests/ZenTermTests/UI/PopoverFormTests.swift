import AppKit
import XCTest

@testable import ZenTerm

final class PopoverFormTests: WindowTestCase {
    private var window: NSWindow!
    private var anchor: NSView!
    private var popover: ListPopover!
    private var headerControl: SegmentedControl!
    private var sectionControl: SegmentedControl!
    private var chosen: [Int] = []

    override func setUp() {
        super.setUp()
        PointerRest.resetForTesting()
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 600),
            styleMask: [.borderless], backing: .buffered, defer: false)
        anchor = NSView(frame: NSRect(x: 20, y: 20, width: 120, height: 28))
        window.contentView?.addSubview(anchor)
        popover = ListPopover(anchor: anchor)
        chosen = []
    }

    override func tearDownWithError() throws {
        popover?.close()
        popover = nil
        window = nil
        PointerRest.resetForTesting()
        try super.tearDownWithError()
    }

    private static let rows = [
        PopoverForm.ChecklistRow(title: "Until I turn it off", isCurrent: true),
        PopoverForm.ChecklistRow(title: "Until agents finish", note: "3 working", isEnabled: false),
        PopoverForm.ChecklistRow(title: "For 30 minutes"),
        PopoverForm.ChecklistRow(title: "For 1 hour"),
    ]

    private func openForm(status: String? = nil, rows: [PopoverForm.ChecklistRow] = rows) -> PopoverForm {
        headerControl = SegmentedControl(options: ["Off", "On"]) { _ in }
        sectionControl = SegmentedControl(options: ["This Mac", "Mac and display"]) { _ in }
        let form = PopoverForm(
            header: PopoverForm.Header(symbol: "cup.and.saucer", title: "Keep Awake", control: headerControl),
            status: status,
            sections: [PopoverForm.Section(caption: "Keep awake", control: sectionControl)],
            checklistCaption: "Until", rows: rows
        ) { [unowned self] in chosen.append($0) }
        popover.open(content: form)
        form.takeFocus()
        return form
    }

    private func press(_ key: TypedKey) throws {
        window.sendEvent(try key.event(in: window))
    }

    private func click(_ view: NSView) throws {
        let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        let target = try XCTUnwrap(window.contentView?.hitTest(point), "nothing takes the click")
        XCTAssertTrue(target === view || target.isDescendant(of: view), "the click lands on something else")
        try sendClick(to: target, at: point)
    }

    private func mouseDown(at point: NSPoint) -> NSEvent {
        NSEvent.mouseEvent(
            with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    private func highlights(_ form: PopoverForm) -> [Bool] { form.rowViewsForTesting.map(\.isHighlighted) }

    func test_opensInTheCard_withEveryRowAndTheCheckOnTheCurrentRow() throws {
        let form = openForm()
        let card = try XCTUnwrap(popover.cardForTesting)

        XCTAssertTrue(form.isDescendant(of: card))
        XCTAssertEqual(form.rowViewsForTesting.map(\.title), Self.rows.map(\.title))
        XCTAssertEqual(form.rowViewsForTesting.map(\.content.trailing), [.check, nil, nil, nil])
        XCTAssertEqual(form.rowViewsForTesting[1].content.note, "3 working", "the detail is the row's note")
        XCTAssertTrue(window.firstResponder === form, "the open form does not take the keyboard")
        XCTAssertEqual(highlights(form), [true, false, false, false], "the cursor opens on the current row")
    }

    func test_aClickOutsideTheCard_closesIt() {
        _ = openForm()

        NSApp.sendEvent(mouseDown(at: NSPoint(x: 480, y: 580)))

        XCTAssertFalse(popover.isOpen)
    }

    func test_aClickInsideTheCard_leavesItOpen() throws {
        let form = openForm()
        let inside = form.convert(NSPoint(x: form.bounds.midX, y: form.bounds.minY + 4), to: nil)

        NSApp.sendEvent(mouseDown(at: inside))

        XCTAssertTrue(popover.isOpen)
    }

    func test_escape_closesIt() throws {
        _ = openForm()

        NSApp.sendEvent(try TypedKey.escape.event(in: window))

        XCTAssertFalse(popover.isOpen)
    }

    func test_arrows_moveTheCursor_skipTheDisabledRow_andStopAtTheEnds() throws {
        let form = openForm()

        try press(.arrowDown)
        XCTAssertEqual(highlights(form), [false, false, true, false], "the cursor landed on a disabled row")
        try press(.arrowDown)
        try press(.arrowDown)
        XCTAssertEqual(highlights(form), [false, false, false, true], "the cursor ran past the last row")
        try press(.arrowUp)
        try press(.arrowUp)
        try press(.arrowUp)
        XCTAssertEqual(highlights(form), [true, false, false, false], "the cursor ran past the first row")
    }

    func test_return_choosesTheCursorRow() throws {
        _ = openForm()

        try press(.arrowDown)
        try press(.returnKey)

        XCTAssertEqual(chosen, [2])
    }

    func test_clickingARow_choosesIt_andADisabledRowDoesNothing() throws {
        let form = openForm()
        let rows = form.rowViewsForTesting

        try click(rows[1])
        XCTAssertEqual(chosen, [], "a disabled row was chosen")
        try click(rows[3])
        XCTAssertEqual(chosen, [3])
    }

    func test_thePointerMovesTheCursor_andTheArrowContinuesFromIt() throws {
        let form = openForm()
        let enter = try XCTUnwrap(
            NSEvent.enterExitEvent(
                with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))

        form.rowViewsForTesting[2].mouseEntered(with: enter)
        XCTAssertEqual(highlights(form), [false, false, true, false])
        form.rowViewsForTesting[1].mouseEntered(with: enter)
        XCTAssertEqual(highlights(form), [false, false, true, false], "the pointer lit a disabled row")

        try press(.arrowDown)
        XCTAssertEqual(highlights(form), [false, false, false, true], "Down did not continue from the pointer's row")
    }

    func test_tab_walksTheHeaderControl_theSectionControl_thenTheChecklist() throws {
        let form = openForm()

        try press(.tab)
        XCTAssertTrue(window.firstResponder === headerControl, "Tab from the checklist did not wrap to the header")
        try press(.tab)
        XCTAssertTrue(window.firstResponder === sectionControl)
        try press(.tab)
        XCTAssertTrue(window.firstResponder === form)
        try press(.arrowDown)
        XCTAssertEqual(highlights(form), [false, false, true, false], "the checklist lost its cursor")
    }

    func test_render_updatesRowsInPlace() throws {
        let form = openForm()
        let before = form.rowViewsForTesting
        var rows = Self.rows
        rows[0].isCurrent = false
        rows[1].isEnabled = true
        rows[1].isCurrent = true
        rows[1].note = "2 working"

        form.render(status: nil, rows: rows, in: popover)

        XCTAssertTrue(form.rowViewsForTesting.elementsEqual(before, by: ===), "the rows were rebuilt")
        XCTAssertEqual(form.rowViewsForTesting.map(\.content.trailing), [nil, .check, nil, nil])
        XCTAssertEqual(form.rowViewsForTesting[1].content.note, "2 working")
    }

    func test_aStatusLineAppearing_growsTheCard_andKeepsFocusAndTheCursor() throws {
        let form = openForm()
        try press(.arrowDown)
        let shortHeight = popover.cardFrame.height

        form.render(
            status: "Awake until 3 working agents finish. The display can still sleep.", rows: Self.rows, in: popover)

        XCTAssertTrue(popover.isOpen)
        XCTAssertGreaterThan(popover.cardFrame.height, shortHeight, "the card did not grow to fit the status line")
        XCTAssertTrue(form.isDescendant(of: try XCTUnwrap(popover.cardForTesting)))
        XCTAssertTrue(window.firstResponder === form, "rebuilding the card dropped the keyboard")
        XCTAssertEqual(highlights(form), [false, false, true, false], "rebuilding the card lost the cursor")
    }

    func test_aStatusLineAppearing_keepsFocusOnTheControlThatHadIt() throws {
        let form = openForm()
        try press(.tab)

        form.render(status: "Awake for 42 more minutes, until 4:31 PM.", rows: Self.rows, in: popover)

        XCTAssertTrue(window.firstResponder === headerControl)
    }
}
