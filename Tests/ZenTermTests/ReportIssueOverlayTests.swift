import AppKit
import XCTest

@testable import ZenTerm

/// Interaction tests for the Report-an-Issue composer, driven through the real controls in a window.
/// A state-only test would pass while a control was dead, the failure mode the project's
/// interaction-test rule guards against.
final class ReportIssueOverlayTests: WindowTestCase {
    private final class Sink {
        var opened: [URL] = []
        var exported = 0
        var cancelled = 0
    }

    private static let sampleReport = SystemReport(
        appVersion: "0.3.0", build: "1234", osVersion: "15.5 (24F74)", architecture: "arm64")

    private var window: NSWindow?

    override func tearDown() {
        window = nil
        super.tearDown()
    }

    // MARK: harness

    private func mount() -> (overlay: ReportIssueOverlay, sink: Sink) {
        let sink = Sink()
        let overlay = ReportIssueOverlay(
            report: Self.sampleReport,
            background: Theme.current.chrome.background.nsColor,
            onOpenURL: { sink.opened.append($0) },
            onExportDiagnostics: { sink.exported += 1 },
            onCancel: { sink.cancelled += 1 })
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 640),
            styleMask: [.borderless], backing: .buffered, defer: false)
        win.contentView?.addSubview(overlay)
        overlay.frame = win.contentView!.bounds
        window = win
        return (overlay, sink)
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func titleField(_ overlay: NSView) -> FieldBox {
        descendants(of: overlay).compactMap { $0 as? FieldBox }.first { $0.placeholder == "A short summary" }!
    }

    private func whatHappened(_ overlay: NSView) -> TextAreaBox {
        descendants(of: overlay).compactMap { $0 as? TextAreaBox }.first!
    }

    private func button(_ overlay: NSView, _ title: String) -> AppButton? {
        descendants(of: overlay).compactMap { $0 as? AppButton }.first { $0.title == title }
    }

    @discardableResult
    private func pressEscape() -> Bool {
        let esc = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false, keyCode: 53)!
        return window!.contentView!.performKeyEquivalent(with: esc)
    }

    private func query(_ url: URL, _ name: String) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
    }

    // MARK: tests

    func test_focusInitialResponder_focusesTitle() {
        let (overlay, _) = mount()
        overlay.focusInitialResponder()
        XCTAssertTrue(KeyboardFocus.isFocused(titleField(overlay).field, in: window))
    }

    func test_environmentBlock_showsTheInjectedReport() {
        let (overlay, _) = mount()
        let shown = descendants(of: overlay)
            .compactMap { $0 as? NSTextField }
            .contains { $0.stringValue == Self.sampleReport.plainText }
        XCTAssertTrue(shown, "the environment being sent is shown verbatim in the card")
    }

    func test_openOnGitHub_withBothFieldsFilled_opensThePrefilledIssue() {
        let (overlay, sink) = mount()
        titleField(overlay).setText("Split closes the pane")
        whatHappened(overlay).setText("It closed the whole pane when I hit cmd-d")

        button(overlay, "Open on GitHub")?.onTap()

        XCTAssertEqual(sink.opened.count, 1)
        let url = sink.opened[0]
        XCTAssertEqual(
            URLComponents(url: url, resolvingAgainstBaseURL: false)?.path,
            "/praxis-labs-io/zen-term/issues/new")
        XCTAssertEqual(query(url, "title"), "Split closes the pane")
        XCTAssertEqual(
            query(url, "body"),
            IssueReport(
                title: "Split closes the pane",
                whatHappened: "It closed the whole pane when I hit cmd-d",
                report: Self.sampleReport
            ).body)
    }

    func test_openOnGitHub_withEmptyRequiredField_doesNotOpen() {
        let (overlay, sink) = mount()
        whatHappened(overlay).setText("something broke")  // title left empty

        button(overlay, "Open on GitHub")?.onTap()

        XCTAssertTrue(sink.opened.isEmpty, "an empty required field blocks opening the issue")
        XCTAssertTrue(KeyboardFocus.isFocused(titleField(overlay).field, in: window), "the offender is focused")
    }

    func test_exportDiagnostics_firesCallbackAndLeavesTheCardUp() {
        let (overlay, sink) = mount()

        button(overlay, "Export Diagnostics…")?.onTap()

        XCTAssertEqual(sink.exported, 1)
        XCTAssertTrue(sink.opened.isEmpty, "exporting doesn't open the issue")
        XCTAssertEqual(sink.cancelled, 0, "exporting leaves the card up")
    }

    func test_escape_cancels() {
        let (overlay, sink) = mount()
        overlay.focusInitialResponder()

        pressEscape()

        XCTAssertEqual(sink.cancelled, 1)
    }

    func test_downArrow_walksTitleToWhatHappenedToOpen() {
        let (overlay, _) = mount()
        let title = titleField(overlay)
        let what = whatHappened(overlay)
        window!.makeFirstResponder(title.field)

        title.onArrowDown?()
        XCTAssertTrue(KeyboardFocus.isFocused(what.textView, in: window), "Down from title reaches what-happened")

        what.onArrowDown?()
        XCTAssertTrue(
            KeyboardFocus.isFocused(button(overlay, "Open on GitHub")!, in: window),
            "Down from what-happened reaches the footer's Open button")
    }

    func test_tab_fromOpenWrapsBackToTitle() {
        let (overlay, _) = mount()
        let open = button(overlay, "Open on GitHub")!
        window!.makeFirstResponder(open)

        open.onTab?()

        XCTAssertTrue(KeyboardFocus.isFocused(titleField(overlay).field, in: window), "Tab off Open wraps to title")
    }
}
