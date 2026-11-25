import AppKit
import XCTest

@testable import ZenTerm

final class ArrowKeysOverRestingPointerTests: WindowTestCase {
    private var pointer = NSPoint(x: 200, y: 200)

    override func setUpWithError() throws {
        try super.setUpWithError()
        PointerRest.pointerLocation = { [unowned self] in pointer }
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func mountPalette() throws -> (HostWindow, [SelectableRowView]) {
        let commands = [
            PaletteCommand(title: "Split Vertically", shortcut: "⌘D", category: .panes, chord: .splitVertical),
            PaletteCommand(title: "Close Pane", shortcut: "⌘W", category: .panes, chord: .closePane),
            PaletteCommand(title: "New Tab", shortcut: "⌘T", category: .panes, chord: .newTab),
        ]
        let overlay = CommandPaletteOverlay(commands: { commands }, onRun: { _ in }, onDismiss: {})
        let window = HostWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 500))
        overlay.translatesAutoresizingMaskIntoConstraints = true
        let content = try XCTUnwrap(window.contentView)
        content.addSubview(overlay)
        overlay.frame = NSRect(x: 0, y: 0, width: 560, height: 420)
        window.layoutIfNeeded()
        let field = try XCTUnwrap(
            descendants(of: overlay).compactMap { $0 as? NSTextField }.first { $0.delegate === overlay })
        XCTAssertTrue(window.makeFirstResponder(field))
        return (window, descendants(of: overlay).compactMap { $0 as? SelectableRowView })
    }

    private func pointerEvent(_ type: NSEvent.EventType, in window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.enterExitEvent(
                with: type, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
    }

    private func press(_ key: TypedKey, in window: NSWindow) throws {
        if let passed = KeyInterceptor().route(try key.event(in: window)) { window.sendEvent(passed) }
    }

    private func pressPaletteChord(in window: NSWindow) throws {
        let event = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "k",
                charactersIgnoringModifiers: "k", isARepeat: false, keyCode: 40))
        let interceptor = KeyInterceptor()
        interceptor.setKeymap([try XCTUnwrap(Chord(event: event)): .toggleCommandPalette])
        XCTAssertNil(interceptor.route(event), "the chord has to be consumed before the window sees it")
    }

    private func selection(_ rows: [SelectableRowView]) -> [Bool] { rows.map(\.isSelected) }

    func test_anArrowPress_keepsItsRow_whenTheRowUnderAStillPointerIsEnteredAgain() throws {
        let (window, rows) = try mountPalette()
        rows[1].mouseEntered(with: try pointerEvent(.mouseEntered, in: window))
        XCTAssertEqual(selection(rows), [false, true, false], "the pointer's row takes the selection")

        try press(.arrowDown, in: window)
        XCTAssertEqual(selection(rows), [false, false, true], "the arrow moves one row")

        rows[1].mouseExited(with: try pointerEvent(.mouseExited, in: window))
        rows[1].mouseEntered(with: try pointerEvent(.mouseEntered, in: window))
        XCTAssertEqual(
            selection(rows), [false, false, true], "hover under a pointer that has not moved took the selection back")
    }

    func test_thePointerTakesTheSelectionAgain_onceItMovesAfterAnArrowPress() throws {
        let (window, rows) = try mountPalette()
        rows[1].mouseEntered(with: try pointerEvent(.mouseEntered, in: window))
        try press(.arrowDown, in: window)
        rows[1].mouseExited(with: try pointerEvent(.mouseExited, in: window))

        pointer.y += 30
        rows[0].mouseEntered(with: try pointerEvent(.mouseEntered, in: window))
        XCTAssertEqual(selection(rows), [true, false, false], "a moved pointer points again")
    }

    func test_aConsumedChord_keepsARowThatOpensUnderAStillPointerFromTakingTheSelection() throws {
        try pressPaletteChord(in: NSWindow())
        let (window, rows) = try mountPalette()

        rows[2].mouseEntered(with: try pointerEvent(.mouseEntered, in: window))
        XCTAssertEqual(selection(rows), [true, false, false], "the palette opens on its first row")
    }
}
