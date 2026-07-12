import AppKit
import XCTest

@testable import ZenTerm

final class KeyboardFocusTests: XCTestCase {
    // MARK: key decoding — the shared keyCode → focus-key map every focus stop routes through

    func test_key_mapsEachNavigationKeyCode() throws {
        XCTAssertEqual(KeyboardFocus.key(for: try keyDown(126)), .up)
        XCTAssertEqual(KeyboardFocus.key(for: try keyDown(125)), .down)
        XCTAssertEqual(KeyboardFocus.key(for: try keyDown(123)), .left)
        XCTAssertEqual(KeyboardFocus.key(for: try keyDown(124)), .right)
        XCTAssertEqual(KeyboardFocus.key(for: try keyDown(53)), .escape)
    }

    func test_key_bundlesReturnEnterSpaceAsActivate() throws {
        XCTAssertEqual(KeyboardFocus.key(for: try keyDown(36)), .activate)  // return
        XCTAssertEqual(KeyboardFocus.key(for: try keyDown(76)), .activate)  // keypad enter
        XCTAssertEqual(KeyboardFocus.key(for: try keyDown(49)), .activate)  // space
    }

    func test_key_bundlesBothDeletesAsDelete() throws {
        XCTAssertEqual(KeyboardFocus.key(for: try keyDown(51)), .delete)  // backspace
        XCTAssertEqual(KeyboardFocus.key(for: try keyDown(117)), .delete)  // forward-delete
    }

    func test_key_tabCarriesShiftState() throws {
        XCTAssertEqual(KeyboardFocus.key(for: try keyDown(48)), .tab(shift: false))
        XCTAssertEqual(KeyboardFocus.key(for: try keyDown(48, shift: true)), .tab(shift: true))
    }

    func test_key_unmappedKeyIsNil() throws {
        XCTAssertNil(KeyboardFocus.key(for: try keyDown(0)))  // 'a' — not a focus key
    }

    private func keyDown(_ code: UInt16, shift: Bool = false) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: shift ? .shift : [],
                timestamp: 0, windowNumber: 0, context: nil,
                characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: code))
    }

    func test_step_movesAndClampsAtEnds() {
        XCTAssertEqual(KeyboardFocus.step(from: 0, delta: 1, count: 3), 1)
        XCTAssertEqual(KeyboardFocus.step(from: 2, delta: 1, count: 3), nil)  // clamp at end
        XCTAssertEqual(KeyboardFocus.step(from: 0, delta: -1, count: 3), nil)  // clamp at start
        XCTAssertEqual(KeyboardFocus.step(from: 1, delta: -1, count: 3), 0)
    }

    func test_step_noAnchor_jumpsToEnd() {
        XCTAssertEqual(KeyboardFocus.step(from: nil, delta: 1, count: 3), 0)  // first
        XCTAssertEqual(KeyboardFocus.step(from: nil, delta: -1, count: 3), 2)  // last
    }

    func test_step_emptyStops_isNil() {
        XCTAssertNil(KeyboardFocus.step(from: nil, delta: 1, count: 0))
    }
}
