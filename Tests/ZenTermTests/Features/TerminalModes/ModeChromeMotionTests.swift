import AppKit
import XCTest

@testable import ZenTerm

@MainActor
final class ModeChromeMotionTests: WindowTestCase {
    private var window: NSWindow!
    private var chrome: ModeChrome!

    override func setUpWithError() throws {
        try super.setUpWithError()
        Motion.isReduceMotionEnabled = { false }
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.borderless], backing: .buffered, defer: false)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        window.contentView?.addSubview(container)
        chrome = ModeChrome(
            container: container, content: content, padding: ChromeMetrics.Spacing.s8,
            header: PanelMeta(title: "Scroll", action: .toggleScrollMode), onStripsChanged: {})
    }

    override func tearDownWithError() throws {
        chrome = nil
        window = nil
        try super.tearDownWithError()
    }

    private func slide(on view: NSView) throws -> NSSize {
        let anim = try XCTUnwrap(view.layer?.animation(forKey: "motion.slide") as? CABasicAnimation)
        return try XCTUnwrap((anim.fromValue as? NSValue)?.sizeValue)
    }

    func test_theFindBar_slidesUpFromTheBottomEdgeAndBackDown() throws {
        let bar = try XCTUnwrap(chrome.setFindBarShown(true))
        XCTAssertLessThan(try slide(on: bar).height, 0, "the bar rises from below the pane's bottom edge")
        XCTAssertNotNil(bar.layer?.animation(forKey: "motion.opacity"))

        chrome.setFindBarShown(false)

        XCTAssertNil(chrome.findBarForTesting, "the search is over the moment the bar is dismissed")
        XCTAssertFalse(bar.isHidden, "the bar leaves by sliding, not by vanishing")
        XCTAssertNotNil(bar.layer?.animation(forKey: "motion.slide"))
        waitUntil(bar.isHidden, "the bar to hide once it has slid out")
    }

    func test_theHeader_slidesDownFromTheTopEdgeAndBackUp() throws {
        chrome.setHeader(PanelMeta(title: "Scroll", action: .toggleScrollMode))
        let header = try XCTUnwrap(chrome.headerViewForTesting)
        XCTAssertGreaterThan(try slide(on: header).height, 0, "the header drops from above the pane's top edge")

        chrome.setHeader(nil)

        XCTAssertFalse(chrome.isHeaderVisibleForTesting)
        XCTAssertFalse(header.isHidden, "the header leaves by sliding, not by vanishing")
        waitUntil(header.isHidden, "the header to hide once it has slid out")
    }

    func test_reopeningTheBarWhileItLeaves_keepsItUp() throws {
        let bar = try XCTUnwrap(chrome.setFindBarShown(true))
        chrome.setFindBarShown(false)

        chrome.setFindBarShown(true)
        let deadline = Date().addingTimeInterval(Motion.pageSlideDuration * 2)
        while Date() < deadline { RunLoop.main.run(mode: .default, before: deadline) }

        XCTAssertFalse(bar.isHidden, "the leaving slide's completion must not hide a bar that came back")
    }
}
