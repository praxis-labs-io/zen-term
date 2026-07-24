import AppKit
import XCTest

@testable import ZenTerm

/// The two key decoders the diff viewer's selection layer rests on (ZEN-227). Both are pure and both
/// fail silently: a decoder that swallows ⌘C steals Copy from the menu, and one that matches against
/// the raw modifier mask stops matching the moment AppKit stamps a `.function` bit on the event — the
/// ZEN-145 trap, which shipped a dead ⌥-reorder past four green tests.
final class DiffVimKeyTests: XCTestCase {
    private func keyDown(
        _ characters: String, unshifted: String? = nil, flags: NSEvent.ModifierFlags = []
    ) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                context: nil, characters: characters,
                charactersIgnoringModifiers: unshifted ?? characters, isARepeat: false, keyCode: 0))
    }

    // MARK: vimKey

    func test_decodesTheMotionAndYankKeys() throws {
        XCTAssertEqual(DiffPaneTable.vimKey(for: try keyDown("j")), .down)
        XCTAssertEqual(DiffPaneTable.vimKey(for: try keyDown("k")), .up)
        XCTAssertEqual(DiffPaneTable.vimKey(for: try keyDown("y")), .yankCode)
        XCTAssertEqual(DiffPaneTable.vimKey(for: try keyDown("g")), .pendingTop)
    }

    func test_theShiftedFormsAreTheirOwnKeys() throws {
        // Shift rides in the character itself, so V and v (or Y and y) can't be confused.
        XCTAssertEqual(DiffPaneTable.vimKey(for: try keyDown("V", unshifted: "v", flags: .shift)), .visual)
        XCTAssertEqual(DiffPaneTable.vimKey(for: try keyDown("G", unshifted: "g", flags: .shift)), .bottom)
        XCTAssertEqual(
            DiffPaneTable.vimKey(for: try keyDown("Y", unshifted: "y", flags: .shift)), .yankReference)
        XCTAssertEqual(DiffPaneTable.vimKey(for: try keyDown("{", unshifted: "[", flags: .shift)), .prevChange)
        XCTAssertEqual(DiffPaneTable.vimKey(for: try keyDown("}", unshifted: "]", flags: .shift)), .nextChange)
    }

    func test_lowercaseVIsNotBound_becauseCharwiseVisualDoesNotExistHere() throws {
        // Selection is linewise only; binding `v` would promise a charwise mode the pane can't do.
        XCTAssertNil(DiffPaneTable.vimKey(for: try keyDown("v")))
    }

    func test_commandOptionAndControlFallThrough_soOtherChordsStillWork() throws {
        // ⌘C must reach `performKeyEquivalent`, ⌃D must reach the half-page handler, and ⌥ anything
        // is somebody else's. A decoder that claimed these would break Copy and the half-page scroll.
        XCTAssertNil(DiffPaneTable.vimKey(for: try keyDown("c", flags: .command)))
        XCTAssertNil(DiffPaneTable.vimKey(for: try keyDown("j", flags: .command)))
        XCTAssertNil(DiffPaneTable.vimKey(for: try keyDown("y", flags: .control)))
        XCTAssertNil(DiffPaneTable.vimKey(for: try keyDown("j", flags: .option)))
    }

    func test_toleratesTheBitsAppKitStamps() throws {
        // A real keyDown carries more than the reservable modifiers; matching the raw mask would miss.
        XCTAssertEqual(DiffPaneTable.vimKey(for: try keyDown("j", flags: .function)), .down)
        XCTAssertEqual(
            DiffPaneTable.vimKey(for: try keyDown("V", unshifted: "v", flags: [.shift, .function])), .visual)
    }

    func test_capsLockDoesNotChangeWhatAKeyMeans() throws {
        // Caps Lock uppercases the characters without setting .shift, so reading shiftedness off the
        // character's case makes j a dead key and turns a single g into a jump to the bottom. The
        // shift has to come from the flags. Nothing on screen would explain either symptom.
        XCTAssertEqual(
            DiffPaneTable.vimKey(for: try keyDown("J", unshifted: "J", flags: .capsLock)), .down)
        XCTAssertEqual(
            DiffPaneTable.vimKey(for: try keyDown("K", unshifted: "K", flags: .capsLock)), .up)
        XCTAssertEqual(
            DiffPaneTable.vimKey(for: try keyDown("G", unshifted: "G", flags: .capsLock)), .pendingTop,
            "still only arms — Caps Lock is not Shift")
        XCTAssertEqual(
            DiffPaneTable.vimKey(for: try keyDown("Y", unshifted: "Y", flags: .capsLock)), .yankCode,
            "a plain yank, not the reference")
    }

    func test_capsLockWithShiftStillReachesTheShiftedForms() throws {
        // With Caps Lock on, Shift *lowercases* the typed character, but the flag is what we read.
        XCTAssertEqual(
            DiffPaneTable.vimKey(for: try keyDown("v", unshifted: "v", flags: [.capsLock, .shift])), .visual)
        XCTAssertEqual(
            DiffPaneTable.vimKey(for: try keyDown("y", unshifted: "y", flags: [.capsLock, .shift])),
            .yankReference)
    }

    func test_bracesDecodeFromTheTypedCharacterAndFromShiftBracket() throws {
        // The literal brace covers any layout that produces one; shift-bracket covers the US layout's
        // charactersIgnoringModifiers, which reports the unshifted bracket.
        XCTAssertEqual(DiffPaneTable.vimKey(for: try keyDown("{", unshifted: "{")), .prevChange)
        XCTAssertEqual(DiffPaneTable.vimKey(for: try keyDown("{", unshifted: "[", flags: .shift)), .prevChange)
        XCTAssertEqual(DiffPaneTable.vimKey(for: try keyDown("}", unshifted: "]", flags: .shift)), .nextChange)
    }

    // MARK: yankShortcut

    func test_yankShortcut_separatesCodeFromReference() throws {
        XCTAssertEqual(DiffViewerOverlay.yankShortcut(for: try keyDown("c", flags: .command)), false)
        XCTAssertEqual(
            DiffViewerOverlay.yankShortcut(for: try keyDown("C", unshifted: "c", flags: [.command, .shift])),
            true)
    }

    func test_yankShortcut_ignoresOtherChords() throws {
        XCTAssertNil(DiffViewerOverlay.yankShortcut(for: try keyDown("c")), "a bare c is a vim key, not Copy")
        XCTAssertNil(DiffViewerOverlay.yankShortcut(for: try keyDown("v", flags: .command)), "⌘V is Paste")
        XCTAssertNil(DiffViewerOverlay.yankShortcut(for: try keyDown("c", flags: [.command, .option])))
    }

    func test_yankShortcut_toleratesTheBitsAppKitStamps() throws {
        XCTAssertEqual(
            DiffViewerOverlay.yankShortcut(for: try keyDown("c", flags: [.command, .function])), false)
    }
}
