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

    private func returnKey() throws -> NSEvent { try key(36, "\r") }

    private func escapeKey() throws -> NSEvent { try key(53, "\u{1b}") }

    private var fieldEditor: NSTextView? { window?.firstResponder as? NSTextView }

    func test_thePlus_addsATab_andSelectsIt() throws {
        mount([Workspace.Tab(main: "nvim")])

        strip.addButtonForTesting.mouseDown(with: try mouse(.leftMouseDown, at: strip.addButtonForTesting))

        XCTAssertEqual(strip.chips.map(\.title), ["nvim", "shell"])
        XCTAssertEqual(strip.chips.map(\.isSelected), [false, true])
    }

    func test_moreTabsThanFit_scrollTheNewestIntoView_andKeepThePlusInTheStrip() throws {
        mount((0..<12).map { Workspace.Tab(name: "a-long-tab-name-\($0)") })

        strip.addButtonForTesting.mouseDown(with: try mouse(.leftMouseDown, at: strip.addButtonForTesting))

        let newest = try XCTUnwrap(strip.chips.last)
        XCTAssertTrue(newest.isSelected)
        XCTAssertTrue(strip.visibleChipsRectForTesting.contains(newest.frame), "the new tab scrolls into view")
        XCTAssertLessThanOrEqual(strip.addButtonForTesting.frame.maxX, strip.bounds.width, "＋ stays in the strip")
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
        strip.addButtonForTesting.mouseDown(with: try mouse(.leftMouseDown, at: strip.addButtonForTesting))
        let newest = try XCTUnwrap(strip.chips.last)

        newest.beginRename()
        window?.contentView?.layoutSubtreeIfNeeded()

        XCTAssertTrue(strip.isRenameHintVisibleForTesting)
        XCTAssertTrue(strip.visibleChipsRectForTesting.contains(newest.frame), "the hint must not push it out of view")
    }

    func test_onlyTheTabThatOpensFocused_carriesTheDot() {
        mount(
            [Workspace.Tab(main: "nvim"), Workspace.Tab(name: "gate")],
            focus: Workspace.LaunchFocus(tab: 1, region: .main))

        XCTAssertEqual(strip.chips.map(\.isDotVisibleForTesting), [false, true])
    }

    func test_aSoleTab_hasNoRemoveButton_andASelectedOneAmongSeveralDoes() {
        mount([Workspace.Tab(main: "nvim")])
        XCTAssertFalse(strip.chips[0].isCloseVisibleForTesting)

        form.addTab()
        rerender()
        XCTAssertEqual(strip.chips.map(\.isCloseVisibleForTesting), [false, true])
    }

    func test_theRemoveButton_removesItsTab() throws {
        mount([Workspace.Tab(main: "nvim"), Workspace.Tab(name: "gate")])
        form.select(1)
        rerender()
        let close = strip.chips[1].closeButtonForTesting

        close.mouseDown(with: try mouse(.leftMouseDown, at: close))

        XCTAssertEqual(strip.chips.map(\.title), ["nvim"])
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

        chip.mouseDown(with: try mouse(.leftMouseDown, at: chip, clicks: 2))

        XCTAssertTrue(chip.isRenaming)
        XCTAssertTrue(strip.isRenameHintVisibleForTesting)
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
