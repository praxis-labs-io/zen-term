import AppKit
import XCTest

@testable import ZenTerm

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

    func test_leftFromRemove_reachesCancel() throws {
        let (card, _) = mount()
        card.focusInitialResponder()
        let remove = try XCTUnwrap(button(in: card, title: "Remove"))

        remove.keyDown(with: try arrowLeft())

        XCTAssertTrue(KeyboardFocus.isFocused(try XCTUnwrap(button(in: card, title: "Cancel")), in: window))
    }

    // MARK: checklist

    func test_theChecklist_readsInOrder_withEachListUnderItsItem() {
        let card = mountChecklist([
            .init(
                mark: .lost, text: [.init(text: "Removing feature/one loses 2 uncommitted files", tone: .ink(.muted))],
                rows: [entry("Sources/", "App.swift", status: "~"), entry("", "notes.md", status: "?")]),
            .init(mark: .info, text: [.init(text: "Closes 1 tab", tone: .ink(.muted))], rows: []),
            .init(mark: .kept, text: [.init(text: "Branch and commits preserved", tone: .ink(.muted))], rows: []),
        ])

        XCTAssertEqual(
            visibleText(in: card).filter { !$0.isEmpty },
            [
                "Remove Worktree", "Removing feature/one loses 2 uncommitted files", "Sources/App.swift", "~",
                "notes.md", "?", "Closes 1 tab", "Branch and commits preserved", "Cancel", "Remove",
            ])
        let icons = descendants(of: card).compactMap { $0 as? NSImageView }
        XCTAssertEqual(icons.count, 3)
        XCTAssertTrue(icons.allSatisfy { $0.image != nil }, "every mark resolves to a symbol")
    }

    func test_aPlainMessage_hasNoChecklist() {
        let (card, _) = mount()

        XCTAssertNil(descendants(of: card).first { $0 is ConfirmCardChecklist })
        XCTAssertNil(list(in: card))
    }

    /// An attributed label ignores the field's own `lineBreakMode`, so the truncation lives in the string.
    func test_aLongPath_truncatesInTheMiddleOnOneLine() throws {
        let longFolder = String(repeating: "deeply/nested/", count: 8)
        let card = mountChecklist([
            .init(
                mark: .lost, text: [.init(text: "x", tone: .ink(.muted))],
                rows: [entry(longFolder, "Keep.swift", status: "+~")])
        ])
        let path = try XCTUnwrap(
            descendants(of: try XCTUnwrap(list(in: card)))
                .compactMap { $0 as? NSTextField }
                .first { $0.stringValue.hasSuffix("Keep.swift") })

        let style = path.attributedStringValue.attribute(.paragraphStyle, at: 0, effectiveRange: nil)
        XCTAssertEqual((style as? NSParagraphStyle)?.lineBreakMode, .byTruncatingMiddle)
        XCTAssertEqual(path.maximumNumberOfLines, 1)
        XCTAssertLessThan(path.frame.width, path.attributedStringValue.size().width)
        XCTAssertLessThanOrEqual(path.frame.height, ConfirmCardList.rowHeight)
    }

    func test_aLongItem_wrapsInsideTheCard() throws {
        let sentence = "Removing " + String(repeating: "feature/a-very-long-branch-name-", count: 4) + " loses 3 files"
        let card = mountChecklist([.init(mark: .lost, text: [.init(text: sentence, tone: .ink(.muted))], rows: [])])
        let label = try XCTUnwrap(
            descendants(of: card).compactMap { $0 as? NSTextField }.first { $0.stringValue == sentence })

        XCTAssertGreaterThan(label.frame.height, ConfirmCardChecklist.textFont.boundingRectForFont.height * 1.5)
        XCTAssertLessThanOrEqual(
            label.alignmentRect(forFrame: label.frame).maxX, try XCTUnwrap(label.superview).bounds.maxX)
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

    private func mountChecklist(_ items: [ConfirmCardChecklist.Item]) -> ConfirmCard {
        let card = ConfirmCard(
            title: "Remove Worktree", items: items, confirmLabel: "Remove",
            background: Theme.current.chrome.background.nsColor, onCancel: {}, onConfirm: {})
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 400),
            styleMask: [.borderless], backing: .buffered, defer: false)
        win.contentView?.addSubview(card)
        card.frame = win.contentView!.bounds
        win.contentView?.layoutSubtreeIfNeeded()
        window = win
        return card
    }

    private func entry(_ folder: String, _ file: String, status: String) -> ConfirmCardList.Row {
        .entry(
            path: [.init(text: folder, tone: .ink(.muted)), .init(text: file, tone: .ink(.subtle))],
            status: [status.map { .init(text: String($0), tone: .role(\.warning)) }])
    }

    private func list(in card: NSView) -> ConfirmCardList? {
        descendants(of: card).compactMap { $0 as? ConfirmCardList }.first
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

    private func arrowLeft() throws -> NSEvent {
        let character = String(UnicodeScalar(NSLeftArrowFunctionKey)!)
        return try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [.function, .numericPad],
                timestamp: 0, windowNumber: 0, context: nil, characters: character,
                charactersIgnoringModifiers: character, isARepeat: false, keyCode: 123))
    }
}
