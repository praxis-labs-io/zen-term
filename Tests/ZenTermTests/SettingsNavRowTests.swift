import AppKit
import XCTest

@testable import ZenTerm

final class SettingsNavRowTests: WindowTestCase {
    func test_focus_showsPaletteFillNotBorder() {
        let (row, window) = mountedRow()

        window.makeFirstResponder(row)
        XCTAssertEqual(row.layer?.backgroundColor, Theme.current.chrome.selectionFill.cgColor)
        XCTAssertEqual(row.layer?.borderWidth, 0)

        window.makeFirstResponder(nil)
        XCTAssertNotEqual(row.layer?.backgroundColor, Theme.current.chrome.selectionFill.cgColor)
    }

    func test_focusFillWinsOverSelectionFill() {
        let (row, window) = mountedRow()

        row.setSelected(true)
        XCTAssertEqual(row.layer?.backgroundColor, Theme.current.chrome.fill(.rest).cgColor)

        window.makeFirstResponder(row)
        XCTAssertEqual(row.layer?.backgroundColor, Theme.current.chrome.selectionFill.cgColor)
    }

    func test_hover_showsHoverFill_andClearsOnExit() {
        let (row, _) = mountedRow()

        row.mouseEntered(with: crossing(.mouseEntered, over: row))
        XCTAssertEqual(row.layer?.backgroundColor, Theme.current.chrome.fill(.hover).cgColor)

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

    func test_hoverFillSitsBetweenFocusAndSelection() {
        let (row, window) = mountedRow()
        row.setSelected(true)

        row.mouseEntered(with: crossing(.mouseEntered, over: row))
        XCTAssertEqual(row.layer?.backgroundColor, Theme.current.chrome.fill(.hover).cgColor)

        window.makeFirstResponder(row)
        XCTAssertEqual(row.layer?.backgroundColor, Theme.current.chrome.selectionFill.cgColor)

        window.makeFirstResponder(nil)
        row.mouseExited(with: crossing(.mouseExited, over: row))
        XCTAssertEqual(row.layer?.backgroundColor, Theme.current.chrome.fill(.rest).cgColor)
    }

    func test_detail_showsTrailingText_inMutedInk() throws {
        let (row, _) = mountedRow()

        row.setDetail("main")

        XCTAssertEqual(row.detailForTesting, "main")
        let detail = try XCTUnwrap(
            row.subviews.compactMap { $0 as? NSTextField }.first { $0.stringValue == "main" })
        XCTAssertEqual(detail.textColor, Theme.current.chrome.ink(.muted))
    }

    func test_click_takesFocus() {
        var activations = 0
        let (row, window) = mountedRow { activations += 1 }

        row.mouseDown(with: click(on: row, in: window))

        XCTAssertTrue(window.firstResponder === row)
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
        onActivate: @escaping () -> Void = {}
    ) -> (SettingsNavRow, NSWindow) {
        let row = SettingsNavRow(title: "Terminal", onActivate: onActivate)
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
