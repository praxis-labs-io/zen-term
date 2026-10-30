import AppKit
import XCTest

@testable import ZenTerm

final class WorkspaceTabStripTests: WindowTestCase {
    private var window: NSWindow?
    private var strip: WorkspaceTabStrip!
    private var form = WorkspaceForm(editing: nil)
    private var renames: [(Int, String)] = []

    override func tearDown() {
        window = nil
        strip = nil
        super.tearDown()
    }

    private func mount(_ tabs: [Workspace.Tab], focus: Workspace.LaunchFocus = .start) {
        form = WorkspaceForm(
            editing: Workspace(title: "W", path: URL(fileURLWithPath: "/tmp"), tabs: tabs, focus: focus, env: [:]))
        let strip = WorkspaceTabStrip()
        strip.onSelect = { [unowned self] in
            form.select($0); rerender()
        }
        strip.onAdd = { [unowned self] in
            form.addTab(); rerender()
        }
        strip.onRemove = { [unowned self] in
            _ = form.removeTab(at: $0); rerender()
        }
        strip.onRename = { [unowned self] index, name in
            renames.append((index, name))
            form.renameTab(at: index, to: name)
            rerender()
        }
        strip.onMove = { [unowned self] from, to in
            form.moveTab(at: from, to: to); rerender()
        }
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 80), styleMask: [.borderless], backing: .buffered,
            defer: false)
        let content = win.contentView!
        content.addSubview(strip)
        NSLayoutConstraint.activate([
            strip.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            strip.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            strip.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
        ])
        self.strip = strip
        window = win
        win.makeKeyAndOrderFront(nil)
        rerender()
    }

    private func rerender() {
        strip.render(form)
        window?.contentView?.layoutSubtreeIfNeeded()
    }

    private func mouse(
        _ type: NSEvent.EventType, at view: NSView, dx: CGFloat = 0, clicks: Int = 1
    ) throws -> NSEvent {
        let center = view.convert(CGPoint(x: view.bounds.midX + dx, y: view.bounds.midY), to: nil)
        return try XCTUnwrap(
            NSEvent.mouseEvent(
                with: type, location: center, modifierFlags: [], timestamp: 0, windowNumber: window!.windowNumber,
                context: nil, eventNumber: 0, clickCount: clicks, pressure: 1))
    }

    private func key(_ code: UInt16, _ characters: String, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: window!.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
    }

    private func rightArrow() throws -> NSEvent {
        try key(124, String(UnicodeScalar(NSRightArrowFunctionKey)!), flags: [.function, .numericPad])
    }

    private func leftArrow() throws -> NSEvent {
        try key(123, String(UnicodeScalar(NSLeftArrowFunctionKey)!), flags: [.function, .numericPad])
    }

    private func returnKey() throws -> NSEvent { try key(36, "\r") }

    private func escapeKey() throws -> NSEvent { try key(53, "\u{1b}") }

    private var fieldEditor: NSTextView? { window?.firstResponder as? NSTextView }

    func test_thePlus_addsATab_andSelectsIt() throws {
        mount([Workspace.Tab(main: "nvim")])

        strip.addButtonForTesting.performClick(nil)

        XCTAssertEqual(strip.chips.map(\.title), ["nvim", "shell"])
        XCTAssertEqual(strip.chips.map(\.isSelected), [false, true])
    }

    func test_moreTabsThanFit_scrollTheNewestIntoView_andKeepThePlusInTheStrip() throws {
        mount((0..<12).map { Workspace.Tab(name: "a-long-tab-name-\($0)") })

        strip.addButtonForTesting.performClick(nil)

        let newest = try XCTUnwrap(strip.chips.last)
        XCTAssertTrue(newest.isSelected)
        XCTAssertTrue(strip.visibleChipsRectForTesting.contains(newest.frame), "the new tab scrolls into view")
        XCTAssertLessThanOrEqual(strip.addButtonForTesting.frame.maxX, strip.bounds.width, "＋ stays in the strip")
    }

    func test_tabsPastAnEdge_fadeOnlyThatEdge() {
        mount((0..<12).map { Workspace.Tab(name: "a-long-tab-name-\($0)") })
        let scroll = strip.chipsScrollForTesting

        XCTAssertTrue(scroll.fadedEdgesForTesting == (false, true), "at the start, only the trailing edge fades")

        form.select(11)
        rerender()

        XCTAssertTrue(scroll.fadedEdgesForTesting == (true, false), "at the end, only the leading edge fades")
    }

    func test_tabsThatFit_fadeNeitherEdge() {
        mount([Workspace.Tab(name: "one"), Workspace.Tab(name: "two")])

        XCTAssertTrue(strip.chipsScrollForTesting.fadedEdgesForTesting == (false, false))
    }

    func test_everyChip_showsItsWholeTitle_selectedOrNot() {
        mount([Workspace.Tab(), Workspace.Tab(name: "gate"), Workspace.Tab(main: "nvim")])

        XCTAssertEqual(strip.chips.map(\.isTitleTruncatedForTesting), [false, false, false])
    }

    func test_aChipThePointerHasLeft_dropsItsHover_whenTheStripLaysOutAgain() throws {
        mount([Workspace.Tab(main: "nvim"), Workspace.Tab(name: "gate"), Workspace.Tab()])
        for chip in strip.chips { chip.mouseEntered(with: try mouse(.mouseMoved, at: chip)) }
        XCTAssertTrue(strip.chips.allSatisfy(\.isHoveredForTesting))

        form.addTab()
        rerender()

        XCTAssertEqual(
            strip.chips.filter(\.isHoveredForTesting).count, 0, "only the chip under the pointer stays hovered")
    }

    func test_renamingAChipAtTheScrolledEnd_keepsItInView_besideTheHint() throws {
        mount((0..<12).map { Workspace.Tab(name: "a-long-tab-name-\($0)") })
        strip.addButtonForTesting.performClick(nil)
        let newest = try XCTUnwrap(strip.chips.last)

        newest.beginRename()
        window?.contentView?.layoutSubtreeIfNeeded()

        XCTAssertTrue(strip.isRenameHintVisibleForTesting)
        XCTAssertTrue(strip.visibleChipsRectForTesting.contains(newest.frame), "the hint must not push it out of view")
    }

    func test_rightFromTheLastChip_reachesThePlus_andLeftComesBack() throws {
        mount([Workspace.Tab(main: "nvim"), Workspace.Tab(name: "gate")])
        form.select(1)
        rerender()
        strip.focusSelectedChip()

        strip.chips[1].keyDown(with: try rightArrow())
        XCTAssertTrue(strip.isAddButtonFocused, "＋ is a keyboard stop after the last chip")

        strip.addButtonForTesting.keyDown(with: try leftArrow())
        XCTAssertIdentical(window?.firstResponder, strip.chips[1])
    }

    func test_voiceOver_seesTheSelectedChip_andCanSelectAnother() {
        mount([Workspace.Tab(main: "nvim"), Workspace.Tab(name: "gate")])
        XCTAssertEqual(strip.chips.map { $0.isAccessibilitySelected() }, [true, false])

        XCTAssertTrue(strip.chips[1].accessibilityPerformPress())

        XCTAssertEqual(form.selected, 1)
        XCTAssertEqual(strip.chips.map { $0.isAccessibilitySelected() }, [false, true])
        XCTAssertIdentical(window?.firstResponder, strip.chips[1])
    }

    func test_onlyTheTabThatOpensFocused_carriesTheDot() {
        mount(
            [Workspace.Tab(main: "nvim"), Workspace.Tab(name: "gate")],
            focus: Workspace.LaunchFocus(tab: 1, region: .main))

        XCTAssertEqual(strip.chips.map(\.isDotVisibleForTesting), [false, true])
    }

    func test_aSoleTab_showsNoRemoveButton_evenOnHover() throws {
        mount([Workspace.Tab(main: "nvim")])
        let chip = strip.chips[0]

        chip.mouseEntered(with: try mouse(.mouseMoved, at: chip))

        XCTAssertTrue(chip.isHoveredForTesting)
        XCTAssertFalse(chip.isCloseVisibleForTesting)
    }

    func test_amongSeveralTabs_theRemoveButtonShowsOnHoverOnly_selectedOrNot() throws {
        mount([Workspace.Tab(main: "nvim"), Workspace.Tab(name: "gate")])
        form.select(1)
        rerender()
        XCTAssertEqual(
            strip.chips.map(\.isCloseVisibleForTesting), [false, false], "none at rest, not even the selected")

        for chip in strip.chips {
            chip.mouseEntered(with: try mouse(.mouseMoved, at: chip))
            XCTAssertTrue(chip.isCloseVisibleForTesting)
            chip.mouseExited(with: try mouse(.mouseMoved, at: chip))
            XCTAssertFalse(chip.isCloseVisibleForTesting)
        }
    }

    func test_hoveringAChip_layingOutItsRemoveButton_conflictsWithNoConstraint() throws {
        let conflicts = try constraintConflicts {
            mount([Workspace.Tab(main: "nvim"), Workspace.Tab(name: "gate")])
            for chip in strip.chips {
                chip.mouseEntered(with: try mouse(.mouseMoved, at: chip))
                chip.layoutSubtreeIfNeeded()
            }
        }

        XCTAssertEqual(conflicts, [])
    }

    func test_aHintWiderThanTheStrip_staysInsideIt() throws {
        mount([Workspace.Tab(main: "nvim")])
        let wide = strip.idleHintFrameForTesting.width

        let conflicts = constraintConflicts {
            window?.setContentSize(NSSize(width: wide / 2 + 40, height: 80))
            window?.contentView?.layoutSubtreeIfNeeded()
        }

        XCTAssertEqual(conflicts, [])
        XCTAssertLessThan(strip.bounds.width, wide, "the strip has to be narrower than the hint")
        XCTAssertLessThanOrEqual(strip.idleHintFrameForTesting.maxX, strip.bounds.width)
    }

    func test_hover_neverChangesAChipsWidth() throws {
        mount(
            [Workspace.Tab(main: "nvim"), Workspace.Tab(name: "gate"), Workspace.Tab()],
            focus: Workspace.LaunchFocus(tab: 1, region: .main))
        for chip in strip.chips {
            let atRest = chip.fittingWidth

            chip.mouseEntered(with: try mouse(.mouseMoved, at: chip))
            XCTAssertEqual(chip.fittingWidth, atRest, "\(chip.title): hover resized the chip")
            chip.mouseExited(with: try mouse(.mouseMoved, at: chip))
        }
    }

    func test_onHover_theRemoveButtonReplacesTheDot_inTheSameSlot() throws {
        mount(
            [Workspace.Tab(main: "nvim"), Workspace.Tab(name: "gate")],
            focus: Workspace.LaunchFocus(tab: 1, region: .main))
        let chip = strip.chips[1]
        let dotFrame = chip.dotFrameForTesting
        XCTAssertEqual(chip.dotColorForTesting, Theme.current.chrome.cursor.nsColor)

        chip.mouseEntered(with: try mouse(.mouseMoved, at: chip))

        XCTAssertFalse(chip.isDotVisibleForTesting)
        XCTAssertTrue(chip.isCloseVisibleForTesting)
        XCTAssertEqual(chip.closeFrameForTesting.midX, dotFrame.midX, accuracy: 0.01)
        XCTAssertEqual(chip.closeFrameForTesting.midY, dotFrame.midY, accuracy: 0.01)
    }

    private var pressed: NSView?

    private func hitTest(at point: CGPoint) -> NSView? { window?.contentView?.superview?.hitTest(point) }

    private func windowPoint(_ view: NSView, dx: CGFloat = 0) -> CGPoint {
        view.convert(CGPoint(x: view.bounds.midX + dx, y: view.bounds.midY), to: nil)
    }

    private func pressDown(at point: CGPoint) throws {
        pressed = hitTest(at: point)
        pressed?.mouseDown(
            with: try XCTUnwrap(
                NSEvent.mouseEvent(
                    with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
                    windowNumber: window!.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)))
    }

    private func pressDrag(to point: CGPoint) throws {
        pressed?.mouseDragged(
            with: try XCTUnwrap(
                NSEvent.mouseEvent(
                    with: .leftMouseDragged, location: point, modifierFlags: [], timestamp: 0,
                    windowNumber: window!.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)))
    }

    private func pressUp(at point: CGPoint) throws {
        pressed?.mouseUp(
            with: try XCTUnwrap(
                NSEvent.mouseEvent(
                    with: .leftMouseUp, location: point, modifierFlags: [], timestamp: 0,
                    windowNumber: window!.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)))
        pressed = nil
    }

    func test_theRemoveButton_removesItsTab_onMouseUp() throws {
        mount([Workspace.Tab(main: "nvim"), Workspace.Tab(name: "gate")])
        form.select(1)
        rerender()
        let chip = strip.chips[1]
        chip.mouseEntered(with: try mouse(.mouseMoved, at: chip))
        let target = windowPoint(chip.closeButtonForTesting)

        try pressDown(at: target)
        XCTAssertEqual(strip.chips.map(\.title), ["nvim", "gate"], "a press alone removes nothing")
        try pressUp(at: target)

        XCTAssertEqual(strip.chips.map(\.title), ["nvim"])
    }

    func test_pressingTheRemoveButton_thenDragging_removesOnce_andNeverReorders() throws {
        mount([Workspace.Tab(main: "a"), Workspace.Tab(main: "b"), Workspace.Tab(main: "c")])
        let chip = strip.chips[1]
        chip.mouseEntered(with: try mouse(.mouseMoved, at: chip))
        let target = windowPoint(chip.closeButtonForTesting)

        try pressDown(at: target)
        try pressDrag(to: CGPoint(x: target.x + 40, y: target.y))
        try pressDrag(to: CGPoint(x: target.x + 120, y: target.y))
        try pressUp(at: target)

        XCTAssertEqual(form.tabs.map(\.main), ["a", "c"], "b is gone and nothing else moved")
        XCTAssertEqual(strip.chips.map(\.title), ["a", "c"])
    }

    func test_doubleClickingTheRemoveButton_downToOneTab_removesOne_andRenamesNothing() throws {
        mount([Workspace.Tab(main: "a"), Workspace.Tab(main: "b")])
        let chip = strip.chips[0]
        chip.mouseEntered(with: try mouse(.mouseMoved, at: chip))
        let target = windowPoint(chip.closeButtonForTesting)

        try pressDown(at: target)
        try pressUp(at: target)
        let survivor = try XCTUnwrap(hitTest(at: target))
        survivor.mouseDown(
            with: try XCTUnwrap(
                NSEvent.mouseEvent(
                    with: .leftMouseDown, location: target, modifierFlags: [], timestamp: 0,
                    windowNumber: window!.windowNumber, context: nil, eventNumber: 0, clickCount: 2, pressure: 1)))

        XCTAssertEqual(form.tabs.map(\.main), ["b"])
        XCTAssertFalse(strip.chips[0].isRenaming, "the second press lands on the survivor, which never took the first")
    }

    func test_aRemovePressDraggedOffTheButton_removesNothing() throws {
        mount([Workspace.Tab(main: "a"), Workspace.Tab(main: "b"), Workspace.Tab(main: "c")])
        let chip = strip.chips[1]
        chip.mouseEntered(with: try mouse(.mouseMoved, at: chip))
        let target = windowPoint(chip.closeButtonForTesting)

        try pressDown(at: target)
        try pressDrag(to: CGPoint(x: target.x + 90, y: target.y))
        try pressUp(at: CGPoint(x: target.x + 90, y: target.y))

        XCTAssertEqual(form.tabs.map(\.main), ["a", "b", "c"])
    }

    func test_thePill_sitsOnTheSelectedChip_throughSelectReorderAndDrag() throws {
        mount([Workspace.Tab(main: "a"), Workspace.Tab(main: "bb"), Workspace.Tab(main: "ccc")])
        XCTAssertEqual(strip.pillColorForTesting, Theme.current.chrome.fill(.active))
        XCTAssertEqual(strip.pillFrameForTesting, strip.chips[0].frame)

        form.select(2)
        rerender()
        XCTAssertEqual(strip.pillFrameForTesting, strip.chips[2].frame, "after select")

        form.moveTab(at: 2, to: 0)
        rerender()
        XCTAssertEqual(form.selected, 0)
        XCTAssertEqual(strip.pillFrameForTesting, strip.chips[0].frame, "after a reorder")

        let chip = strip.chips[0]
        chip.mouseDown(with: try mouse(.leftMouseDown, at: chip))
        chip.mouseDragged(with: try mouse(.leftMouseDragged, at: chip, dx: 30))
        chip.mouseDragged(with: try mouse(.leftMouseDragged, at: chip, dx: 60))
        window?.contentView?.layoutSubtreeIfNeeded()
        XCTAssertEqual(strip.pillFrameForTesting, chip.frame, "the pill follows the dragged chip")
        chip.mouseUp(with: try mouse(.leftMouseUp, at: chip))
    }

    func test_renaming_hidesTheRemoveButton_andFloorsTheChipAtTheMinimumWidth() throws {
        mount([Workspace.Tab(main: "nvim"), Workspace.Tab(name: "gate")])
        let chip = strip.chips[1]

        chip.beginRename()
        chip.mouseEntered(with: try mouse(.mouseMoved, at: chip))
        chip.renameFieldForTesting.stringValue = "a"

        XCTAssertTrue(chip.isHoveredForTesting)

        XCTAssertFalse(chip.isCloseVisibleForTesting, "no x while the field is open")
        XCTAssertEqual(chip.fittingWidth, TabChip.minWidth, "a short name still gets the floor")

        chip.renameFieldForTesting.stringValue = String(repeating: "m", count: 12)
        let measured = ceil(
            (String(repeating: "m", count: 12) as NSString).size(withAttributes: [.font: TabChip.chipFont]).width)
        XCTAssertEqual(
            chip.fittingWidth, 2 * TabChip.labelInset + measured + ChromeMetrics.Spacing.s12, accuracy: 0.01,
            "the typed text plus the pad")
    }

    func test_rightArrowOnAFocusedChip_selectsAndFocusesTheNextOne() throws {
        mount([Workspace.Tab(main: "nvim"), Workspace.Tab(name: "gate")])
        strip.focusSelectedChip()

        strip.chips[0].keyDown(with: try rightArrow())

        XCTAssertEqual(form.selected, 1)
        XCTAssertIdentical(window?.firstResponder, strip.chips[1])
    }

    func test_doubleClick_renamesInline_andReturnCommits() throws {
        mount([Workspace.Tab(main: "nvim"), Workspace.Tab(main: "bin/check")])
        let chip = strip.chips[1]

        chip.mouseDown(with: try mouse(.leftMouseDown, at: chip))
        chip.mouseUp(with: try mouse(.leftMouseUp, at: chip))
        chip.mouseDown(with: try mouse(.leftMouseDown, at: chip, clicks: 2))

        XCTAssertTrue(strip.isIdleHintVisibleForTesting == false && strip.isRenameHintVisibleForTesting)
        XCTAssertTrue(chip.isRenaming)
        XCTAssertEqual(chip.renameFieldForTesting.placeholderAttributedString?.string, "bin/check")
        let editor = try XCTUnwrap(fieldEditor, "the inline field has to take the keyboard")
        editor.string = "gate"
        editor.keyDown(with: try returnKey())

        XCTAssertEqual(form.tabs[1].name, "gate")
        XCTAssertEqual(strip.chips[1].title, "gate")
        XCTAssertFalse(strip.chips[1].isRenaming)
        XCTAssertFalse(strip.isRenameHintVisibleForTesting)
        XCTAssertIdentical(window?.firstResponder, strip.chips[1], "Return hands the keyboard back to the chip")
    }

    func test_returnOnAFocusedChip_startsTheRename() throws {
        mount([Workspace.Tab(main: "nvim")])
        strip.focusSelectedChip()

        strip.chips[0].keyDown(with: try returnKey())

        XCTAssertTrue(strip.chips[0].isRenaming)
        XCTAssertNotNil(fieldEditor)
    }

    func test_escapeCancelsTheRename_andKeepsTheName() throws {
        mount([Workspace.Tab(name: "code", main: "nvim")])
        strip.beginRenamingSelected()
        let editor = try XCTUnwrap(fieldEditor)
        editor.string = "changed"

        editor.keyDown(with: try escapeKey())

        XCTAssertFalse(strip.chips[0].isRenaming)
        XCTAssertEqual(form.tabs[0].name, "code")
        XCTAssertTrue(renames.isEmpty)
    }

    func test_anEmptyRename_goesBackToTheNameItWouldGetAnyway() throws {
        mount([Workspace.Tab(name: "code", main: "nvim")])
        strip.beginRenamingSelected()
        let editor = try XCTUnwrap(fieldEditor)
        editor.string = ""

        editor.keyDown(with: try returnKey())

        XCTAssertNil(form.tabs[0].name)
        XCTAssertEqual(strip.chips[0].title, "nvim")
    }

    func test_draggingAChipPastItsNeighbour_movesTheTab() throws {
        mount([Workspace.Tab(main: "a"), Workspace.Tab(main: "b"), Workspace.Tab(main: "c")])
        let chip = strip.chips[0]
        let distance = strip.chips[1].frame.maxX - chip.frame.midX + 2

        chip.mouseDown(with: try mouse(.leftMouseDown, at: chip))
        chip.mouseDragged(with: try mouse(.leftMouseDragged, at: chip, dx: distance / 2))
        chip.mouseDragged(with: try mouse(.leftMouseDragged, at: chip, dx: distance))
        chip.mouseUp(with: try mouse(.leftMouseUp, at: chip, dx: distance))

        XCTAssertEqual(form.tabs.map(\.main), ["b", "a", "c"])
        XCTAssertEqual(strip.chips.map(\.title), ["b", "a", "c"])
    }

    func test_aClickWithoutDragging_onlySelects() throws {
        mount([Workspace.Tab(main: "a"), Workspace.Tab(main: "b")])
        let chip = strip.chips[1]

        chip.mouseDown(with: try mouse(.leftMouseDown, at: chip))
        chip.mouseUp(with: try mouse(.leftMouseUp, at: chip))

        XCTAssertEqual(form.tabs.map(\.main), ["a", "b"])
        XCTAssertEqual(form.selected, 1)
        XCTAssertIdentical(window?.firstResponder, strip.chips[1])
    }
}
