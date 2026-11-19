import AppKit
import XCTest

@testable import ZenTerm

final class NavRowTests: WindowTestCase {
    func test_focus_showsTheRingWithoutAFill() {
        let (row, window) = mountedRow()

        window.makeFirstResponder(row)
        XCTAssertEqual(row.layer?.backgroundColor, NSColor.clear.cgColor)
        XCTAssertEqual(row.layer?.borderWidth, ChromeMetrics.Border.width)
        XCTAssertEqual(row.layer?.borderColor, Theme.current.chrome.focusRing.cgColor)

        window.makeFirstResponder(nil)
        XCTAssertEqual(row.layer?.backgroundColor, NSColor.clear.cgColor)
        XCTAssertEqual(
            row.layer?.borderWidth, ChromeMetrics.Border.width, "focus changes the ring's color, not its width")
        XCTAssertEqual(row.layer?.borderColor?.alpha, 0)
    }

    func test_focus_keepsTheCurrentFill() {
        let (row, window) = mountedRow()

        row.isCurrent = true
        XCTAssertEqual(row.layer?.backgroundColor, Theme.current.chrome.fill(.active).cgColor)

        window.makeFirstResponder(row)
        XCTAssertEqual(row.layer?.backgroundColor, Theme.current.chrome.fill(.active).cgColor)
        XCTAssertEqual(row.layer?.borderColor, Theme.current.chrome.focusRing.cgColor)
    }

    func test_hover_showsHoverFill_andClearsOnExit() {
        let (row, _) = mountedRow()

        row.mouseEntered(with: crossing(.mouseEntered, over: row))
        XCTAssertEqual(row.layer?.backgroundColor, Theme.current.chrome.fill(.hover).cgColor)
        XCTAssertEqual(row.layer?.borderColor?.alpha, 0, "hover shares focus's fill, so only focus draws the ring")

        row.mouseExited(with: crossing(.mouseExited, over: row))
        XCTAssertEqual(row.layer?.backgroundColor, NSColor.clear.cgColor)
    }

    func test_hidingAnAncestor_clearsTheHoverFill() {
        let (row, window) = mountedRow()
        let holder = NSView(frame: window.contentView?.bounds ?? .zero)
        window.contentView?.addSubview(holder)
        holder.addSubview(row)
        row.mouseEntered(with: crossing(.mouseEntered, over: row))

        holder.isHidden = true
        holder.isHidden = false

        XCTAssertEqual(
            row.layer?.backgroundColor, NSColor.clear.cgColor,
            "hiding delivers no mouseExited, so a row shown again would keep a hover the pointer left")
    }

    func test_hoverFillWinsOverTheCurrentFill() {
        let (row, window) = mountedRow()
        row.isCurrent = true

        row.mouseEntered(with: crossing(.mouseEntered, over: row))
        XCTAssertEqual(row.layer?.backgroundColor, Theme.current.chrome.fill(.hover).cgColor)

        window.makeFirstResponder(row)
        XCTAssertEqual(row.layer?.backgroundColor, Theme.current.chrome.fill(.hover).cgColor)
        XCTAssertEqual(row.layer?.borderColor, Theme.current.chrome.focusRing.cgColor)

        window.makeFirstResponder(nil)
        XCTAssertEqual(row.layer?.borderColor?.alpha, 0)
        row.mouseExited(with: crossing(.mouseExited, over: row))
        XCTAssertEqual(row.layer?.backgroundColor, Theme.current.chrome.fill(.active).cgColor)
    }

    func test_detail_showsTrailingText_inMutedInk() throws {
        let (row, _) = mountedRow()

        row.setDetail("main")

        XCTAssertEqual(row.detailForTesting, "main")
        let detail = try XCTUnwrap(
            descendants(of: row).compactMap { $0 as? NSTextField }.first { $0.stringValue == "main" })
        XCTAssertEqual(detail.textColor, Theme.current.chrome.ink(.muted))
    }

    func test_hover_swapsTheDetailForTheHoverAccessory() {
        let (row, _) = mountedRow()
        let plus = NSButton(title: "+", target: nil, action: nil)
        row.setDetail("main")
        row.setHoverAccessory(plus)
        row.layoutSubtreeIfNeeded()
        func showsDetail() -> Bool { descendants(of: row).contains { ($0 as? NSTextField)?.stringValue == "main" } }
        XCTAssertFalse(descendants(of: row).contains { $0 === plus })
        XCTAssertTrue(showsDetail())

        row.mouseEntered(with: crossing(.mouseEntered, over: row))

        XCTAssertTrue(descendants(of: row).contains { $0 === plus })
        XCTAssertFalse(showsDetail(), "the detail gives way")
        XCTAssertTrue(row.bounds.contains(plus.convert(plus.bounds, to: row)), "the accessory is not placed yet")
        XCTAssertGreaterThan(plus.frame.width, 0)

        row.mouseExited(with: crossing(.mouseExited, over: row))

        XCTAssertFalse(descendants(of: row).contains { $0 === plus })
        XCTAssertTrue(showsDetail())
    }

    func test_aThemeChange_reachesTheHoverAccessoryWhileItIsOutOfTheRow() {
        let (row, _) = mountedRow()
        let plus = ThemeRecorder()
        row.setHoverAccessory(plus)
        XCTAssertNil(plus.superview, "premise: the accessory waits outside the row until hover")

        row.reapplyThemeTree()

        XCTAssertEqual(plus.reapplied, 1, "the accessory comes back on hover in the old theme")
    }

    private final class ThemeRecorder: NSView, ThemeReapplying {
        var reapplied = 0
        func reapplyTheme() { reapplied += 1 }
    }

    func test_hover_placesThePlusWhereAClickThroughTheWindowLands() throws {
        let (row, window) = mountedRow()
        let plus = IconButton(symbol: "plus", accessibilityLabel: "New worktree") {}
        row.setHoverAccessory(plus)
        row.layoutSubtreeIfNeeded()

        row.mouseEntered(with: crossing(.mouseEntered, over: row))

        let point = plus.convert(NSPoint(x: plus.bounds.midX, y: plus.bounds.midY), to: nil)
        let target = try XCTUnwrap(window.contentView?.hitTest(point))
        XCTAssertTrue(target === plus || target.isDescendant(of: plus), "the click lands on \(target), not the plus")
    }

    func test_hover_keepsALongTitleClearOfThePlus() throws {
        let (row, _) = mountedRow()
        let long = String(repeating: "a-very-long-workspace-name-", count: 4)
        row.setTitle(long)
        let plus = IconButton(symbol: "plus", accessibilityLabel: "New worktree") {}
        row.setHoverAccessory(plus)
        let title = try XCTUnwrap(
            descendants(of: row).compactMap { $0 as? NSTextField }.first { $0.stringValue == long })

        row.mouseEntered(with: crossing(.mouseEntered, over: row))
        row.layoutSubtreeIfNeeded()

        XCTAssertTrue(title.isDescendant(of: row), "hover replaced the title label")
        XCTAssertLessThanOrEqual(
            title.convert(title.bounds, to: row).maxX, plus.convert(plus.bounds, to: row).minX,
            "the title truncates before the plus, not under it")
    }

    func test_click_takesFocus() {
        var activations = 0
        let (row, window) = mountedRow { activations += 1 }

        row.mouseDown(with: click(on: row, in: window))

        XCTAssertTrue(window.firstResponder === row)
        XCTAssertEqual(activations, 1)
    }

    func test_click_onAKeyboardOnlyRow_activatesAndLeavesFocusAlone() {
        var activations = 0
        let (row, window) = mountedRow(focusesOnClick: false) { activations += 1 }
        let focusHolder = FocusHolder(frame: NSRect(x: 0, y: 30, width: 10, height: 10))
        window.contentView?.addSubview(focusHolder)
        window.makeFirstResponder(focusHolder)

        row.mouseDown(with: click(on: row, in: window))

        XCTAssertTrue(window.firstResponder === focusHolder, "the click activates the row without taking focus")
        XCTAssertEqual(activations, 1)
        XCTAssertFalse(row.acceptsFirstResponder, "AppKit promotes a clicked view that accepts first responder")
    }

    func test_keyboardOnlyRow_takesKeyboardFocus_andKeepsIt() {
        let (row, window) = mountedRow(focusesOnClick: false)

        row.takeKeyboardFocus()

        XCTAssertTrue(window.firstResponder === row)
        XCTAssertEqual(row.layer?.backgroundColor, NSColor.clear.cgColor)
        XCTAssertEqual(row.layer?.borderColor, Theme.current.chrome.focusRing.cgColor)
    }

    private final class FocusHolder: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    func test_accessibility_announcesAButtonWithItsTitleDetailAndSelection() {
        var activations = 0
        let (row, _) = mountedRow { activations += 1 }
        row.setDetail("main")
        row.isCurrent = true

        XCTAssertTrue(row.isAccessibilityElement())
        XCTAssertEqual(row.accessibilityRole(), .button)
        XCTAssertEqual(row.accessibilityLabel(), "Terminal")
        XCTAssertEqual(row.accessibilityValue() as? String, "main")
        XCTAssertTrue(row.isAccessibilitySelected())
        row.isCurrent = false
        XCTAssertFalse(row.isAccessibilitySelected())

        XCTAssertTrue(row.accessibilityPerformPress())
        XCTAssertEqual(activations, 1)
    }

    func test_return_andKeypadEnter_callOnReturn() {
        let (row, window) = mountedRow()
        var returns = 0
        row.onReturn = { returns += 1 }
        window.makeFirstResponder(row)

        window.sendEvent(key(36, in: window))
        window.sendEvent(key(76, [.function, .numericPad], in: window))

        XCTAssertEqual(returns, 2)
    }

    func test_escape_callsOnEscape() {
        let (row, window) = mountedRow()
        var escapes = 0
        row.onEscape = { escapes += 1 }
        window.makeFirstResponder(row)

        window.sendEvent(key(53, in: window))

        XCTAssertEqual(escapes, 1)
    }

    func test_modifiedEscape_doesNotCallOnEscape() {
        let (row, window) = mountedRow()
        var escapes = 0
        row.onEscape = { escapes += 1 }
        window.makeFirstResponder(row)

        for modifier in [NSEvent.ModifierFlags.command, .option, .control] {
            window.sendEvent(key(53, modifier, in: window))
        }

        XCTAssertEqual(escapes, 0, "only a bare Esc leaves, as only a bare Return activates")
    }

    func test_withoutCallbacks_returnAndEscapeReachTheNextResponder() {
        let (row, window) = mountedRow()
        let parent = KeyRecorder(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        window.contentView?.addSubview(parent)
        parent.addSubview(row)
        window.makeFirstResponder(row)

        window.sendEvent(key(36, in: window))
        window.sendEvent(key(53, in: window))

        XCTAssertEqual(parent.keyCodes, [36, 53], "a row with no callbacks leaves Return and Esc to its container")
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private final class KeyRecorder: NSView {
        var keyCodes: [UInt16] = []
        override func keyDown(with event: NSEvent) { keyCodes.append(event.keyCode) }
    }

    private func key(_ keyCode: UInt16, _ flags: NSEvent.ModifierFlags = [], in window: NSWindow) -> NSEvent {
        let text = keyCode == 53 ? "\u{1b}" : "\r"
        return NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text,
            isARepeat: false, keyCode: keyCode)!
    }

    private func crossing(_ type: NSEvent.EventType, over row: NSView) -> NSEvent {
        NSEvent.enterExitEvent(
            with: type, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: row.window?.windowNumber ?? 0, context: nil, eventNumber: 0,
            trackingNumber: 0, userData: nil)!
    }

    private func click(on row: NSView, in window: NSWindow) -> NSEvent {
        let point = row.convert(NSPoint(x: row.bounds.midX, y: row.bounds.midY), to: nil)
        return NSEvent.mouseEvent(
            with: .leftMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    private func mountedRow(
        focusesOnClick: Bool = true, onActivate: @escaping () -> Void = {}
    ) -> (NavRow, NSWindow) {
        let row = NavRow(title: "Terminal", focusesOnClick: focusesOnClick, onActivate: onActivate)
        row.translatesAutoresizingMaskIntoConstraints = true
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 40),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.makeKeyAndOrderFront(nil)
        window.contentView?.addSubview(row)
        row.frame = NSRect(x: 0, y: 0, width: 200, height: 30)
        return (row, window)
    }
}
