import AppKit
import PaneKit
import XCTest

@testable import ZenTerm

/// The comment composer driven through the real key path in a real window (ZEN-257): every send here
/// goes `performKeyEquivalent` → the composer → the send closure, and every target pick goes through
/// the dropdown's own control. A version that called `send` directly, or set the selected index on the
/// view model, would stay green with the keys unwired and the dropdown dead — which is exactly how a
/// fully broken dropdown shipped past two reviews before.
final class DiffCommentComposerTests: XCTestCase {
    private var window: NSWindow?
    private var originalConfig: GeneralConfig!

    /// What the composer handed back, if anything.
    private struct Sent {
        let message: String
        let target: DiffSendTarget
        let submit: Bool
    }
    private var sent: [Sent] = []
    private var cancels = 0

    override func setUp() {
        super.setUp()
        originalConfig = GeneralConfig.current
        GeneralConfig.setCurrentForTesting(.builtIn)
        sent = []
        cancels = 0
    }

    override func tearDown() {
        GeneralConfig.setCurrentForTesting(originalConfig)
        window = nil
        super.tearDown()
    }

    // MARK: harness

    private static let targets = [
        DiffSendTarget(id: PaneID(1), label: "pane 1 · zsh"),
        DiffSendTarget(id: PaneID(2), label: "pane 2 · claude"),
        DiffSendTarget(id: PaneID(Int.min), label: "bottom drawer"),
    ]

    private func mount(
        reference: String = "Sources/App/Foo.swift:42-44", removedLines: [String] = [],
        targets: [DiffSendTarget] = DiffCommentComposerTests.targets
    ) -> DiffCommentComposer {
        let composer = DiffCommentComposer(
            reference: reference, removedLines: removedLines, targets: targets,
            onSend: { [weak self] message, target, submit in
                self?.sent.append(Sent(message: message, target: target, submit: submit))
            },
            onCancel: { [weak self] in self?.cancels += 1 })
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.borderless], backing: .buffered, defer: false)
        win.contentView?.addSubview(composer)
        composer.frame = win.contentView!.bounds
        win.contentView?.layoutSubtreeIfNeeded()
        window = win
        composer.focusInitialResponder()
        return composer
    }

    /// Press a key the way `NSWindow.sendEvent` does — a `performKeyEquivalent` traversal from the
    /// content view down, so the composer's claim has to actually be reachable through AppKit's walk.
    @discardableResult
    private func press(
        keyCode: UInt16, flags: NSEvent.ModifierFlags = [], characters: String = "\r",
        file: StaticString = #filePath, line: UInt = #line
    ) throws -> Bool {
        let event = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                context: nil, characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: keyCode),
            file: file, line: line)
        return window!.contentView!.performKeyEquivalent(with: event)
    }

    private func type(_ text: String, into composer: DiffCommentComposer) {
        composer.noteViewForTesting.insertText(text, replacementRange: NSRange(location: 0, length: 0))
    }

    // MARK: send

    func test_returnSendsWithoutSubmitting() throws {
        let composer = mount()
        type("reuse centerRow here", into: composer)

        XCTAssertTrue(try press(keyCode: 36), "the composer claims a bare Return")
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?.message, "Sources/App/Foo.swift:42-44 reuse centerRow here")
        XCTAssertEqual(
            sent.first?.submit, false,
            "⏎ leaves the message in the input — an agent mid-run must not be fired at by accident")
    }

    func test_commandReturnSendsAndSubmits() throws {
        let composer = mount()
        type("ship it", into: composer)

        XCTAssertTrue(try press(keyCode: 36, flags: .command))
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?.message, "Sources/App/Foo.swift:42-44 ship it")
        XCTAssertEqual(sent.first?.submit, true)
    }

    func test_shiftReturnIsLeftToTheTextView() throws {
        let composer = mount()
        type("first line", into: composer)

        XCTAssertFalse(
            try press(keyCode: 36, flags: .shift),
            "unclaimed, so it reaches the text view and takes a new line — the chat-input convention")
        XCTAssertTrue(sent.isEmpty, "and nothing is sent")
    }

    func test_escapeCancelsWithoutSending() throws {
        let composer = mount()
        type("never mind", into: composer)

        XCTAssertTrue(try press(keyCode: 53, characters: "\u{1b}"))
        XCTAssertEqual(cancels, 1)
        XCTAssertTrue(sent.isEmpty)
    }

    func test_anEmptyNoteSendsTheBareReference() throws {
        _ = mount()
        XCTAssertTrue(try press(keyCode: 36))
        XCTAssertEqual(
            sent.first?.message, "Sources/App/Foo.swift:42-44",
            "select, ⏎, ⏎ is the fast path — a reference with no note is a legitimate message")
    }

    func test_removedLinesRideAlongInTheSentMessage() throws {
        let composer = mount(reference: "Sources/App/Foo.swift:41", removedLines: ["    gone()"])
        type("why?", into: composer)

        XCTAssertTrue(try press(keyCode: 36))
        XCTAssertEqual(sent.first?.message, "Sources/App/Foo.swift:41 why?\n\nRemoved lines:\n    gone()")
    }

    func test_keypadEnterSendsToo() throws {
        _ = mount()
        XCTAssertTrue(try press(keyCode: 76, characters: "\u{3}"))
        XCTAssertEqual(sent.count, 1)
    }

    // MARK: target

    func test_theDefaultTargetIsTheFirstOne() throws {
        let composer = mount()
        XCTAssertEqual(
            composer.selectedTargetForTesting, Self.targets[0],
            "the tab hands its list focused-first, so index 0 is where you were working")

        XCTAssertTrue(try press(keyCode: 36))
        XCTAssertEqual(sent.first?.target, Self.targets[0])
    }

    func test_pickingATargetThroughTheDropdownRoutesTheSendThere() throws {
        let composer = mount()
        let dropdown = composer.targetDropdownForTesting
        // The real open → highlight → commit path. Return here reaches the dropdown's own `keyDown`,
        // which is why the composer must not claim it while the list is open.
        dropdown.openListForTesting()
        XCTAssertTrue(dropdown.isPopoverOpen)
        dropdown.moveHighlightForTesting(1)
        XCTAssertFalse(
            try press(keyCode: 36),
            "an open list owns Return — the composer stays out of the way")
        window!.makeFirstResponder(dropdown)
        dropdown.keyDown(with: try returnEvent())

        XCTAssertFalse(dropdown.isPopoverOpen, "the pick closed the list")
        XCTAssertEqual(composer.selectedTargetForTesting, Self.targets[1])

        XCTAssertTrue(try press(keyCode: 36))
        XCTAssertEqual(sent.first?.target, Self.targets[1], "the send follows the picked target")
    }

    func test_escapeWithTheListOpenClosesTheListNotTheComposer() throws {
        let composer = mount()
        let dropdown = composer.targetDropdownForTesting
        dropdown.openListForTesting()
        window!.makeFirstResponder(dropdown)

        XCTAssertFalse(try press(keyCode: 53, characters: "\u{1b}"), "the composer yields Esc")
        dropdown.keyDown(with: try escapeEvent())

        XCTAssertFalse(dropdown.isPopoverOpen)
        XCTAssertEqual(cancels, 0, "a comment isn't thrown away by closing a dropdown")
    }

    private func returnEvent() throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false,
                keyCode: 36))
    }

    private func escapeEvent() throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                isARepeat: false, keyCode: 53))
    }
}
