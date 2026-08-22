import AppKit
import XCTest

@testable import ZenTerm

/// The ⌘⇧ arrows over a text view, through the real interceptor and into a real one.
///
/// `KeyInterceptor` resolves the keymap ahead of the responder chain, so binding the prompt jumps
/// on ⌘⇧↑/⌘⇧↓ took extend-to-start and extend-to-end-of-document away from the Report an Issue
/// composer. Over a modal card it is worse than a no-op, because `WindowController.handle` swallows
/// an unrecognised chord silently.
///
/// The assertions drive the text view's own selection rather than the guard's return value. A guard
/// that answers `true` while the keystroke still selects nothing is the failure this exists to
/// catch, and only the real control can tell the two apart. That is also how ⌘A was measured OUT of
/// the owned set: AppKit serves Select All from an Edit menu item ZenTerm has never had, so it does
/// nothing in a field whatever the guard says.
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
        // Multi-line, because the two chords under test are document-scoped: on one line there is
        // no difference between extending to the start of the document and to the start of the row.
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

    /// The interceptor wired the way `AppDelegate` wires it, minus the nav half, which has its own
    /// suite. The shipped keymap rather than a stub: the prompt jumps being defaults on these two
    /// chords is the whole premise.
    ///
    /// Reads this window's responder where `AppDelegate` reads `NSApp.keyWindow`'s. An unactivated
    /// test process has no key window, and a keystroke in production implies one by construction,
    /// so forcing the app active here would test XCTest rather than the guard. The lookup itself is
    /// the same one-liner `AppDelegate.keyController` already uses.
    private func interceptor() -> KeyInterceptor {
        let keys = KeyInterceptor()
        keys.passThroughGuard = { [weak self] chord, _ in
            TextEditingChords.owns(chord, firstResponder: self?.window.firstResponder)
        }
        return keys
    }

    /// A caret mid-document, so extending to either end is a visible move in both directions.
    private static let caret = NSRange(location: 14, length: 0)

    // MARK: the text view keeps its own chords

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

    /// The mirror, and the one that stops the guard from being a blanket pass-through: a chord the
    /// text system has no use for is still ZenTerm's while a field holds the keyboard, or focusing
    /// a filter field would brick ⌘T.
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

    // MARK: Return belongs to the box you are typing in

    /// Fill Screen is ⌘⏎, and the interceptor resolves ahead of the responder chain, so without
    /// the guard a composer's own decoder never sees the keystroke. `route` has to hand the real
    /// event back, not merely answer true: an event the composer can no longer read is no use.
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

    /// ⇧⏎ is a composer's new-line escape hatch, so ⌘⇧⏎ has to reach the text view too rather than
    /// firing Focus Mode over it.
    func test_commandShiftReturnReachesItAsWell() throws {
        window.makeFirstResponder(view)
        let keys = interceptor()
        var fired: [KeyInterceptor.ReservedChord] = []
        keys.onReservedChord = { fired.append($0) }

        let event = try returnKeyDown(flags: [.command, .shift])

        XCTAssertIdentical(keys.route(event), event)
        XCTAssertEqual(fired, [])
    }

    /// And with nothing focused they are the window's again, or Fill Screen would only work while
    /// you happened not to be typing.
    func test_theReturnChordsFireTheWindowActionsWhenNoTextViewHasTheKeyboard() throws {
        window.makeFirstResponder(nil)
        let keys = interceptor()
        var fired: [KeyInterceptor.ReservedChord] = []
        keys.onReservedChord = { fired.append($0) }

        XCTAssertNil(keys.route(try returnKeyDown(flags: .command)))
        XCTAssertNil(keys.route(try returnKeyDown(flags: [.command, .shift])))
        XCTAssertEqual(fired, [.fillScreen, .toggleZoom])
    }

    private func returnKeyDown(flags: NSEvent.ModifierFlags) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "\r",
                charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
    }

    // MARK: and the pane keeps them when no text view is focused

    func test_theArrowsFireThePromptJumpWhenNoTextViewHasTheKeyboard() throws {
        window.makeFirstResponder(nil)
        let keys = interceptor()
        var fired: [KeyInterceptor.ReservedChord] = []
        keys.onReservedChord = { fired.append($0) }

        XCTAssertNil(keys.route(try arrowKeyDown(keyCode: 126, character: "\u{F700}")))
        XCTAssertNil(keys.route(try arrowKeyDown(keyCode: 125, character: "\u{F701}")))
        XCTAssertEqual(fired, [.jumpToPreviousPrompt, .jumpToNextPrompt])
    }

    // MARK: the predicate's own truth table

    func test_theArrowsAreOwnedByATextViewAndNotByAnythingElse() {
        let up = Chord(command: true, shift: true, key: "↑")
        let textView = NSTextView()

        XCTAssertTrue(TextEditingChords.owns(up, firstResponder: textView))
        XCTAssertFalse(TextEditingChords.owns(up, firstResponder: NSView()))
        XCTAssertFalse(TextEditingChords.owns(up, firstResponder: nil))
    }

    /// ⌘A is deliberately absent from this set, and measurement is why: AppKit serves Select All
    /// from a menu item rather than from the text view, so deferring the chord here would hand it to
    /// nobody at all. The Edit menu serves it instead, and the keymap ships no default on it, so it
    /// never reaches this guard in the first place.
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
