import AppKit
import XCTest

@testable import ZenTerm

/// Every form card shares one cap and one scroll, so a card that opts out of `FormCard.content`
/// grows with its content and becomes a full-height wall on a tall display. Mounted in a window
/// far taller than the cap, which is where a missing constraint shows and a laptop hides it.
final class FormCardHeightTests: WindowTestCase {
    /// The form arms a chord capture on open; nothing here presses a key.
    private final class NoCapture: KeybindCapturing {
        func beginCapture(_ handler: @escaping (NSEvent) -> Void) {}
        func endCapture() {}
    }

    private var window: NSWindow?

    override func tearDown() {
        window = nil
        super.tearDown()
    }

    func test_theToolFloatForm_staysUnderTheCap() throws {
        let overlay = ToolFloatFormOverlay(
            editing: nil, existingIDs: [], capturer: NoCapture(),
            background: Theme.current.chrome.background.nsColor,
            onSubmit: { _ in }, onCancel: {})
        XCTAssertLessThanOrEqual(try cardHeight(of: overlay), FormCard.maxHeight)
    }

    /// A guard, not a regression catcher: this card's copy line truncates to one line, so it
    /// cannot reach the cap today. It is here so that stops being silently true.
    func test_theCreateWorktreeCard_staysUnderTheCap() throws {
        let workspace = Workspace(
            title: "ZenTerm", path: URL(fileURLWithPath: "/tmp/zenterm-fixture"),
            main: nil, right: nil, bottom: nil, focus: .main, env: [:],
            carry: (0..<30).map { "entry-\($0)" })
        let overlay = NewWorktreeOverlay(
            workspace: workspace,
            options: WorktreeStore.CreateOptions(
                branches: [], defaultBase: "origin/main", currentBranch: "main", holders: [:]),
            background: Theme.current.chrome.background.nsColor,
            onSubmit: { _, _ in }, onCancel: {}, onDismiss: {})
        XCTAssertLessThanOrEqual(try cardHeight(of: overlay), FormCard.maxHeight)
    }

    /// The cap must make the body scroll, not squash it. As a two-way equality the content-fit
    /// constraint outranked the labels' compression resistance and laid every caption in the form
    /// out at zero height: still present, still "visible", and invisible on screen.
    func test_aCappedCard_scrollsItsBodyRatherThanFlatteningIt() throws {
        let ws = Workspace(
            title: "W", path: FileManager.default.temporaryDirectory, main: "a", right: "b",
            bottom: "c", focus: .main,
            env: Dictionary(uniqueKeysWithValues: (0..<10).map { ("KEY\($0)", "v") }),
            carry: [".env"])
        let overlay = AddWorkspaceOverlay(
            editing: ws, existingTitles: [], background: Theme.current.chrome.background.nsColor,
            onSubmit: { _ in }, onCancel: {})
        _ = try cardHeight(of: overlay)

        func walk(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(walk) }
        let captions = walk(overlay).compactMap { $0 as? FieldCaption }
        XCTAssertGreaterThan(captions.count, 5, "expected the form's captions")
        for caption in captions {
            XCTAssertGreaterThan(
                caption.frame.height, 0, "'\(caption.stringValue)' laid out flat")
        }
    }

    private func cardHeight(of overlay: NSView) throws -> CGFloat {
        overlay.translatesAutoresizingMaskIntoConstraints = true
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 1600),
            styleMask: [.borderless], backing: .buffered, defer: false)
        win.contentView?.addSubview(overlay)
        overlay.frame = win.contentView!.bounds
        window = win
        win.contentView?.layoutSubtreeIfNeeded()

        func walk(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(walk) }
        let card = try XCTUnwrap(walk(overlay).compactMap { $0 as? CardView }.first)
        XCTAssertGreaterThan(card.frame.height, 0)
        return card.frame.height
    }
}
