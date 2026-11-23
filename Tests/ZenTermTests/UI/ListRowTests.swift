import AppKit
import XCTest

@testable import ZenTerm

final class ListRowTests: WindowTestCase {
    private var window: NSWindow!

    override func setUpWithError() throws {
        try super.setUpWithError()
        Motion.isReduceMotionEnabled = { false }
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 400),
            styleMask: [.borderless], backing: .buffered, defer: false)
    }

    private var hover: CGColor { Theme.current.chrome.fill(.hover).cgColor }

    private func mount(_ row: ListRow) -> ListRow {
        row.translatesAutoresizingMaskIntoConstraints = true
        window.contentView?.addSubview(row)
        row.frame = NSRect(x: 20, y: 20, width: 220, height: ChromeMetrics.Height.control)
        row.layoutSubtreeIfNeeded()
        return row
    }

    private func click(_ view: NSView) throws {
        let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        let target = try XCTUnwrap(view.window?.contentView?.hitTest(point), "nothing takes the click")
        try sendClick(to: target, at: point)
    }

    private func crossing(_ type: NSEvent.EventType) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.enterExitEvent(
                with: type, location: NSPoint(x: 30, y: 30), modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
    }

    private func rows(in view: NSView?) -> [ListRow] {
        guard let view else { return [] }
        return view.subviews.flatMap { ($0 as? ListRow).map { [$0] } ?? rows(in: $0) }
    }

    func test_aClickOnTheRow_choosesIt() throws {
        var chosen = 0
        let row = mount(ListRow(ListRow.Content(title: "Rename", note: "Note", trailing: .check)) { chosen += 1 })

        try click(row)

        XCTAssertEqual(chosen, 1)
    }

    func test_theKeyboardCursorAndThePointer_eachFillTheRow() throws {
        let row = mount(ListRow(ListRow.Content(title: "Nord")) {})
        XCTAssertEqual(row.layer?.backgroundColor?.alpha, 0, "a row at rest is clear")

        row.isHighlighted = true
        XCTAssertEqual(row.layer?.backgroundColor, hover, "the keyboard cursor does not fill the row")
        row.isHighlighted = false
        XCTAssertEqual(row.layer?.backgroundColor?.alpha, 0, "the cursor's fill stays after it moves on")

        row.mouseEntered(with: try crossing(.mouseEntered))
        XCTAssertEqual(row.layer?.backgroundColor, hover, "the pointer does not fill the row")
        row.mouseExited(with: try crossing(.mouseExited))
        XCTAssertEqual(row.layer?.backgroundColor?.alpha, 0)
    }

    func test_aClickNeverFocusesTheRow_butTakeKeyboardFocusRingsIt() {
        let row = mount(ListRow(ListRow.Content(title: "General")) {})

        XCTAssertFalse(row.acceptsFirstResponder, "AppKit would make a clicked row first responder")

        row.takeKeyboardFocus()
        XCTAssertTrue(window.firstResponder === row)
        XCTAssertFalse(row.isTakingKeyboardFocus, "the row keeps accepting focus after taking it")
        XCTAssertEqual(row.layer?.borderColor, Theme.current.chrome.focusRing.cgColor)

        window.makeFirstResponder(nil)
        XCTAssertEqual(row.layer?.borderColor?.alpha, 0, "the ring stays after focus leaves")
    }

    func test_aThemeChange_keepsTheSameRunningSpinner() throws {
        let row = mount(ListRow(ListRow.Content(title: "Removing one…", leading: .spinner)) {})
        func spinner() -> Spinner? {
            func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
            return descendants(row).compactMap { $0 as? Spinner }.first
        }
        let before = try XCTUnwrap(spinner())

        row.reapplyTheme()

        XCTAssertTrue(spinner() === before, "a rebuild restarts the spinner from its first frame")
        XCTAssertTrue(before.isSpinning)
    }

    func test_aProcessChip_isKeptAcrossARenderAndAThemeChange_andShowsTheNewProgram() throws {
        let row = mount(ListRow(ListRow.Content(title: "server", leading: .process(.shell))) {})
        let before = try XCTUnwrap(row.processBadgeForTesting, "a process leading draws no chip")
        XCTAssertTrue(before.isDescendant(of: row))

        row.render(ListRow.Content(title: "server", leading: .process(ProcessIcon.forProgram("nvim"))))
        row.reapplyTheme()

        XCTAssertTrue(row.processBadgeForTesting === before, "a new program swaps the chip, so it cannot crossfade")
        XCTAssertTrue(before.isDescendant(of: row), "the kept chip left the row")
        XCTAssertEqual(before.process?.name, "Neovim")
    }

    func test_branchField_highlightsWithTheArrow_andAClickedRowCommitsItsBranch() throws {
        let field = BranchField()
        window.contentView?.addSubview(field)
        field.frame = NSRect(x: 20, y: 300, width: 420, height: ChromeMetrics.Height.control)
        field.setBranches(["feature/zen-454", "feature/zen-481"], notes: [:])
        field.box.setText("zen")
        field.box.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field.field))
        field.box.control(field.field, textView: NSTextView(), doCommandBy: #selector(NSResponder.moveDown(_:)))

        let shown = rows(in: window.contentView)
        XCTAssertEqual(shown.map(\.title), ["feature/zen-454", "feature/zen-481"])
        XCTAssertEqual(shown.map(\.isHighlighted), [false, true], "the arrow did not move the highlight")
        XCTAssertEqual(shown[1].layer?.backgroundColor, hover)
        shown[0].mouseEntered(with: try crossing(.mouseEntered))
        XCTAssertEqual(shown.map(\.isHighlighted), [true, false], "the pointer did not move the highlight")
        XCTAssertEqual(shown[1].layer?.backgroundColor?.alpha, 0, "two rows are lit")

        try click(shown[0])
        XCTAssertEqual(field.text, "feature/zen-454")
        XCTAssertFalse(field.isListOpen)
    }

    func test_branchField_theArrowStopsAtTheEnds() {
        let field = BranchField()
        window.contentView?.addSubview(field)
        field.frame = NSRect(x: 20, y: 300, width: 420, height: ChromeMetrics.Height.control)
        field.setBranches(["feature/zen-454", "feature/zen-481"], notes: [:])
        field.box.setText("zen")
        field.box.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field.field))
        func arrow(_ selector: Selector) {
            field.box.control(field.field, textView: NSTextView(), doCommandBy: selector)
        }

        arrow(#selector(NSResponder.moveUp(_:)))
        XCTAssertEqual(field.highlightedForTesting, "feature/zen-454", "Up wrapped from the first branch")
        arrow(#selector(NSResponder.moveDown(_:)))
        arrow(#selector(NSResponder.moveDown(_:)))
        XCTAssertEqual(field.highlightedForTesting, "feature/zen-481", "Down wrapped from the last branch")
        XCTAssertTrue(field.isListOpen)
    }

    func test_rowMenu_thePointerMovesTheCursor_andTheArrowContinuesFromIt() throws {
        let anchor = NSView(frame: NSRect(x: 20, y: 300, width: 200, height: ChromeMetrics.Height.control))
        window.contentView?.addSubview(anchor)
        let menu = SidebarRowMenu()
        let item = { (title: String) in SidebarRowMenu.Item(title: title, action: nil) {} }
        menu.open([[item("Rename"), item("Duplicate")], [item("Close")]], from: anchor)
        let items = menu.itemViewsForTesting

        items[1].mouseEntered(with: try crossing(.mouseEntered))
        XCTAssertEqual(menu.highlightedTitleForTesting, "Duplicate")
        XCTAssertEqual(items.map { $0.layer?.backgroundColor == hover }, [false, true, false])

        menu.moveHighlight(1)
        XCTAssertEqual(menu.highlightedTitleForTesting, "Close")
        XCTAssertEqual(items.map { $0.layer?.backgroundColor == hover }, [false, false, true], "two rows are lit")
        menu.moveHighlight(1)
        XCTAssertEqual(menu.highlightedTitleForTesting, "Close", "Down wrapped from the last item")
    }

    func test_rowMenu_aClickedItemRunsItsCommand_andClosesTheMenu() throws {
        let anchor = NSView(frame: NSRect(x: 20, y: 300, width: 200, height: ChromeMetrics.Height.control))
        window.contentView?.addSubview(anchor)
        var ran: [String] = []
        let menu = SidebarRowMenu()
        menu.open(
            [
                [SidebarRowMenu.Item(title: "Rename", action: nil) { ran.append("Rename") }],
                [SidebarRowMenu.Item(title: "Close", action: nil) { ran.append("Close") }],
            ],
            from: anchor)
        let items = menu.itemViewsForTesting
        XCTAssertEqual(items.map(\.title), ["Rename", "Close"])

        try click(try XCTUnwrap(items.last))

        XCTAssertEqual(ran, ["Close"])
        XCTAssertFalse(menu.isOpen)
    }
}
