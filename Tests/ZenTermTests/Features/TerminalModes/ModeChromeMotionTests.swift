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
            header: nil, onStripsChanged: {})
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

    func test_theFindField_dropsInFromTheTopEdgeAndBackUp() throws {
        let field = try XCTUnwrap(chrome.setFindFieldShown(true))
        XCTAssertGreaterThan(try slide(on: field).height, 0, "the field drops in from above the pane's top edge")
        XCTAssertNotNil(field.layer?.animation(forKey: "motion.opacity"))

        chrome.setFindFieldShown(false)

        XCTAssertNil(chrome.findFieldForTesting, "the search is over the moment the field is dismissed")
        XCTAssertFalse(field.isHidden, "the field leaves by sliding, not by vanishing")
        XCTAssertNotNil(field.layer?.animation(forKey: "motion.slide"))
        waitUntil(field.isHidden, "the field to hide once it has slid out")
    }

    func test_dismissingTheFieldWhileItArrives_slidesItBackOut() throws {
        let field = try XCTUnwrap(chrome.setFindFieldShown(true))
        chrome.setFindFieldShown(false)
        let soon = Date().addingTimeInterval(Motion.pageSlideDuration / 4)
        while Date() < soon { RunLoop.main.run(mode: .default, before: soon) }

        XCTAssertFalse(field.isHidden, "the replaced arrival's completion must not cut the leaving slide short")
        waitUntil(field.isHidden, "the field to hide once it has slid out")
    }

    func test_aLeavingField_takesNoClicks() throws {
        let field = try XCTUnwrap(chrome.setFindFieldShown(true))
        window.contentView?.layoutSubtreeIfNeeded()
        let center = NSPoint(x: field.frame.midX, y: field.frame.midY)
        XCTAssertNotNil(field.hitTest(center), "premise: a shown field takes clicks")

        chrome.setFindFieldShown(false)

        XCTAssertFalse(field.isHidden, "premise: the field is still sliding out")
        XCTAssertNil(field.hitTest(center), "a click on the leaving field would focus a field nothing listens to")
    }

    func test_reopeningTheFieldWhileItLeaves_keepsItUp() throws {
        let field = try XCTUnwrap(chrome.setFindFieldShown(true))
        chrome.setFindFieldShown(false)

        chrome.setFindFieldShown(true)
        let deadline = Date().addingTimeInterval(Motion.pageSlideDuration * 2)
        while Date() < deadline { RunLoop.main.run(mode: .default, before: deadline) }

        XCTAssertFalse(field.isHidden, "the leaving slide's completion must not hide a field that came back")
    }
}
