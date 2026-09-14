import AppKit
import XCTest

@testable import ZenTerm

@MainActor
final class TextEditingChordsTests: WindowTestCase {
    private var window: NSWindow!
    private var view: NSTextView!

    override func setUpWithError() throws {
        try super.setUpWithError()
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        view = NSTextView(frame: NSRect(x: 0, y: 0, width: 280, height: 180))
        view.string = "line one\nline two\nline three"
        window.contentView?.addSubview(view)
        window.makeKeyAndOrderFront(nil)
    }

    override func tearDownWithError() throws {
        window = nil
        view = nil
        try super.tearDownWithError()
    }

    private func interceptor() -> KeyInterceptor {
        let keys = KeyInterceptor()
        keys.passThroughGuard = { [weak self] chord, _ in
            TextEditingChords.owns(chord, firstResponder: self?.window.firstResponder)
        }
        return keys
    }

    private static let caret = NSRange(location: 14, length: 0)

    func test_commandShiftUpExtendsTheSelectionToTheStartOfTheDocument() throws {
        window.makeFirstResponder(view)
        view.setSelectedRange(Self.caret)
        let keys = interceptor()
        var fired: [KeyInterceptor.ReservedChord] = []
        keys.onReservedChord = { fired.append($0) }

        let event = try arrowKeyDown(keyCode: 126, character: "\u{F700}")
        XCTAssertIdentical(keys.route(event), event, "the guard has to hand the real event back")
        view.keyDown(with: event)

        XCTAssertEqual(
            view.selectedRange(), NSRange(location: 0, length: 14),
            "the text view did not extend its selection, so the chord is still being eaten")
        XCTAssertEqual(fired, [], "and the prompt jump must not have run behind it")
    }

    func test_commandShiftDownExtendsTheSelectionToTheEndOfTheDocument() throws {
        window.makeFirstResponder(view)
        view.setSelectedRange(Self.caret)
        let keys = interceptor()

        let event = try arrowKeyDown(keyCode: 125, character: "\u{F701}")
        XCTAssertIdentical(keys.route(event), event)
        view.keyDown(with: event)

        XCTAssertEqual(view.selectedRange(), NSRange(location: 14, length: 14))
    }

    func test_anUnrelatedChordStillFiresOverAFocusedTextView() throws {
        window.makeFirstResponder(view)
        let keys = interceptor()
        var fired: [KeyInterceptor.ReservedChord] = []
        keys.onReservedChord = { fired.append($0) }

        XCTAssertNil(
            keys.route(
                try XCTUnwrap(
                    NSEvent.keyEvent(
                        with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                        windowNumber: window.windowNumber, context: nil, characters: "t",
                        charactersIgnoringModifiers: "t", isARepeat: false, keyCode: 17))))
        XCTAssertEqual(fired, [.newTab])
    }

    func test_commandReturnReachesTheComposersOwnDecoder() throws {
        window.makeFirstResponder(view)
        let keys = interceptor()
        var fired: [KeyInterceptor.ReservedChord] = []
        keys.onReservedChord = { fired.append($0) }

        let event = try returnKeyDown(flags: .command)
        let passed = try XCTUnwrap(keys.route(event), "the guard has to hand the real event back")

        XCTAssertIdentical(passed, event)
        XCTAssertEqual(fired, [], "and Fill Screen must not have run behind it")
    }

    func test_commandShiftReturnReachesItAsWell() throws {
        window.makeFirstResponder(view)
        let keys = interceptor()
        var fired: [KeyInterceptor.ReservedChord] = []
        keys.onReservedChord = { fired.append($0) }

        let event = try returnKeyDown(flags: [.command, .shift])

        XCTAssertIdentical(keys.route(event), event)
        XCTAssertEqual(fired, [])
    }

    func test_theReturnChordsFireTheWindowActionsWhenNoTextViewHasTheKeyboard() throws {
        window.makeFirstResponder(nil)
        let keys = interceptor()
        var fired: [KeyInterceptor.ReservedChord] = []
        keys.onReservedChord = { fired.append($0) }

        XCTAssertNil(keys.route(try returnKeyDown(flags: .command)))
        XCTAssertNil(keys.route(try returnKeyDown(flags: [.command, .shift])))
        XCTAssertEqual(fired, [.fillScreen, .toggleZoom])
    }

    private func pickerInterceptor() -> KeyInterceptor {
        let keys = KeyInterceptor()
        keys.passThroughGuard = { [weak self] chord, action in
            TextEditingChords.owns(chord, firstResponder: self?.window.firstResponder)
                || PickerChordGuard.shouldPassThrough(action: action, repoPickerIsOpen: true)
        }
        return keys
    }

    func test_optionDeleteInThePickersField_deletesAWordAndRemovesNothing() throws {
        view.string = "zen term"
        window.makeFirstResponder(view)
        view.setSelectedRange(NSRange(location: 8, length: 0))
        let keys = pickerInterceptor()
        var fired: [KeyInterceptor.ReservedChord] = []
        keys.onReservedChord = { fired.append($0) }

        let event = try deleteKeyDown(flags: .option)
        XCTAssertIdentical(keys.route(event), event, "the field has to get the real event")
        view.keyDown(with: event)

        XCTAssertEqual(fired, [], "⌥⌫ while filtering must not raise the remove confirm")
        XCTAssertEqual(view.string, "zen ")
    }

    func test_commandShiftDeleteInThePickersField_removesTheWorktree() throws {
        view.string = "zen term"
        window.makeFirstResponder(view)
        let keys = pickerInterceptor()
        var fired: [KeyInterceptor.ReservedChord] = []
        keys.onReservedChord = { fired.append($0) }

        XCTAssertNil(keys.route(try deleteKeyDown(flags: [.command, .shift])))
        XCTAssertEqual(fired, [.removeWorktree])
        XCTAssertEqual(view.string, "zen term")
    }

    private func deleteKeyDown(flags: NSEvent.ModifierFlags) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "\u{7f}",
                charactersIgnoringModifiers: "\u{7f}", isARepeat: false, keyCode: 51))
    }

    private func returnKeyDown(flags: NSEvent.ModifierFlags) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "\r",
                charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
    }

    func test_theArrowsFireThePromptJumpWhenNoTextViewHasTheKeyboard() throws {
        window.makeFirstResponder(nil)
        let keys = interceptor()
        var fired: [KeyInterceptor.ReservedChord] = []
        keys.onReservedChord = { fired.append($0) }

        XCTAssertNil(keys.route(try arrowKeyDown(keyCode: 126, character: "\u{F700}")))
        XCTAssertNil(keys.route(try arrowKeyDown(keyCode: 125, character: "\u{F701}")))
        XCTAssertEqual(fired, [.jumpToPreviousPrompt, .jumpToNextPrompt])
    }

    func test_theArrowsAreOwnedByATextViewAndNotByAnythingElse() {
        let up = Chord(command: true, shift: true, key: "↑")
        let textView = NSTextView()

        XCTAssertTrue(TextEditingChords.owns(up, firstResponder: textView))
        XCTAssertFalse(TextEditingChords.owns(up, firstResponder: NSView()))
        XCTAssertFalse(TextEditingChords.owns(up, firstResponder: nil))
    }

    func test_commandAIsNotTreatedAsATextViewChord() {
        XCTAssertFalse(
            TextEditingChords.owns(Chord(command: true, key: "a"), firstResponder: NSTextView()))
        XCTAssertNil(KeymapDefaults.map[Chord(command: true, key: "a")])
    }

    private func arrowKeyDown(keyCode: UInt16, character: String) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero,
                modifierFlags: [.command, .shift, .function, .numericPad], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: character,
                charactersIgnoringModifiers: character, isARepeat: false, keyCode: keyCode))
    }
}
