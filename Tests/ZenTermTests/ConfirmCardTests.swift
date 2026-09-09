import AppKit
import XCTest

@testable import ZenTerm

/// The confirm shown over a card that stays put, driven through its real controls in a window.
/// It answers a consequence that cannot be taken back, so every way out of it has to work.
final class ConfirmCardTests: WindowTestCase {
    private final class Sink {
        var confirmed = 0
        var cancelled = 0
    }

    private var window: NSWindow?

    override func setUp() {
        super.setUp()
        Motion.isReduceMotionEnabled = { true }
    }

    override func tearDown() {
        window = nil
        super.tearDown()
    }

    func test_theTitleAndTheConsequenceAreOnScreen() {
        let (card, _) = mount(message: "feature/one has 3 uncommitted files.")

        let text = visibleText(in: card)
        XCTAssertTrue(text.contains("Remove Worktree"), "\(text)")
        XCTAssertTrue(text.contains("feature/one has 3 uncommitted files."), "\(text)")
    }

    /// Return answers the question the card just asked, so the affirmative holds focus.
    func test_returnOnTheFocusedButton_confirms() throws {
        let (card, sink) = mount()
        card.focusInitialResponder()
        let remove = try XCTUnwrap(button(in: card, title: "Remove"))
        XCTAssertTrue(KeyboardFocus.isFocused(remove, in: window))

        remove.keyDown(with: try returnKey())

        XCTAssertEqual(sink.confirmed, 1)
        XCTAssertEqual(sink.cancelled, 0)
    }

    func test_escCancels() throws {
        let (card, sink) = mount()
        card.focusInitialResponder()

        XCTAssertTrue(card.performKeyEquivalent(with: try escapeKey()))

        XCTAssertEqual(sink.cancelled, 1)
        XCTAssertEqual(sink.confirmed, 0)
    }

    /// Clicking out of a confirm answers it: no.
    func test_clickingTheBackdropCancels() throws {
        let (card, sink) = mount()

        try XCTUnwrap(backdrop(in: card)).mouseDown(with: NSEvent())

        XCTAssertEqual(sink.cancelled, 1)
        XCTAssertEqual(sink.confirmed, 0)
    }

    func test_theCancelButtonCancels() throws {
        let (card, sink) = mount()

        try XCTUnwrap(button(in: card, title: "Cancel")).onTap()

        XCTAssertEqual(sink.cancelled, 1)
        XCTAssertEqual(sink.confirmed, 0)
    }

    /// Left and right walk the pair, so the safe answer is reachable without the mouse.
    func test_leftFromRemove_reachesCancel() throws {
        let (card, _) = mount()
        card.focusInitialResponder()
        let remove = try XCTUnwrap(button(in: card, title: "Remove"))

        remove.keyDown(with: try arrowLeft())

        XCTAssertTrue(KeyboardFocus.isFocused(try XCTUnwrap(button(in: card, title: "Cancel")), in: window))
    }

    // MARK: harness

    private func mount(message: String = "feature/one has nothing uncommitted.") -> (
        card: ConfirmCard, sink: Sink
    ) {
        let sink = Sink()
        let card = ConfirmCard(
            title: "Remove Worktree", message: message, confirmLabel: "Remove",
            background: Theme.current.chrome.background.nsColor,
            onCancel: { sink.cancelled += 1 },
            onConfirm: { sink.confirmed += 1 })
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 400),
            styleMask: [.borderless], backing: .buffered, defer: false)
        win.contentView?.addSubview(card)
        card.frame = win.contentView!.bounds
        win.contentView?.layoutSubtreeIfNeeded()
        window = win
        return (card, sink)
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func button(in card: NSView, title: String) -> AppButton? {
        descendants(of: card).compactMap { $0 as? AppButton }.first { $0.title == title }
    }

    private func backdrop(in card: NSView) -> BackdropView? {
        descendants(of: card).compactMap { $0 as? BackdropView }.first
    }

    private func visibleText(in card: NSView) -> [String] {
        descendants(of: card)
            .compactMap { $0 as? NSTextField }
            .filter { !$0.isEditable && !$0.isHiddenOrHasHiddenAncestor }
            .map(\.stringValue)
    }

    private func returnKey() throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false,
                keyCode: 36))
    }

    private func escapeKey() throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                isARepeat: false, keyCode: 53))
    }

    /// AppKit hangs `.function` and `.numericPad` on every arrow; without them this is a
    /// keystroke macOS never sends.
    private func arrowLeft() throws -> NSEvent {
        let character = String(UnicodeScalar(NSLeftArrowFunctionKey)!)
        return try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [.function, .numericPad],
                timestamp: 0, windowNumber: 0, context: nil, characters: character,
                charactersIgnoringModifiers: character, isARepeat: false, keyCode: 123))
    }
}
