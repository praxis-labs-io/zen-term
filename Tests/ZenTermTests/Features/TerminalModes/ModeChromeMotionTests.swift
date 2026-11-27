import AppKit
import XCTest

@testable import ZenTerm

@MainActor
final class ModeChromeMotionTests: WindowTestCase {
    private var window: NSWindow!
    private var chrome: ModeChrome!
    private var originalConfig: GeneralConfig!

    override func setUpWithError() throws {
        try super.setUpWithError()
        originalConfig = GeneralConfig.current
        GeneralConfig.setCurrentForTesting(.builtIn)
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
            header: PaneHeader(
                content: .init(process: .shell, name: "zsh", path: nil), controls: [.close], onControl: { _ in }),
            onStripsChanged: {})
    }

    override func tearDownWithError() throws {
        chrome = nil
        window = nil
        GeneralConfig.setCurrentForTesting(originalConfig)
        try super.tearDownWithError()
    }

    func test_theFindField_fadesInAndOut() throws {
        let field = try XCTUnwrap(chrome.setFindFieldShown(true))
        XCTAssertNotNil(field.layer?.animation(forKey: "motion.opacity"), "the field fades into the header's row")

        chrome.setFindFieldShown(false)

        XCTAssertNil(chrome.findFieldForTesting, "the search is over the moment the field is dismissed")
        XCTAssertFalse(field.isHidden, "the field leaves by fading, not by vanishing")
        XCTAssertNotNil(field.layer?.animation(forKey: "motion.opacity"))
        waitUntil(field.isHidden, "the field to hide once it has faded out")
    }

    func test_dismissingTheFieldWhileItArrives_fadesItBackOut() throws {
        let field = try XCTUnwrap(chrome.setFindFieldShown(true))
        chrome.setFindFieldShown(false)
        let soon = Date().addingTimeInterval(Motion.fadeDuration / 4)
        while Date() < soon { RunLoop.main.run(mode: .default, before: soon) }

        XCTAssertFalse(field.isHidden, "the replaced arrival's completion must not cut the leaving fade short")
        waitUntil(field.isHidden, "the field to hide once it has faded out")
    }

    func test_aLeavingField_takesNoClicks() throws {
        let field = try XCTUnwrap(chrome.setFindFieldShown(true))
        window.contentView?.layoutSubtreeIfNeeded()
        let center = NSPoint(x: field.frame.midX, y: field.frame.midY)
        XCTAssertNotNil(field.hitTest(center), "premise: a shown field takes clicks")

        chrome.setFindFieldShown(false)

        XCTAssertFalse(field.isHidden, "premise: the field is still fading out")
        XCTAssertNil(field.hitTest(center), "a click on the leaving field would focus a field nothing listens to")
    }

    func test_reopeningTheFieldWhileItLeaves_keepsItUp() throws {
        let field = try XCTUnwrap(chrome.setFindFieldShown(true))
        chrome.setFindFieldShown(false)

        chrome.setFindFieldShown(true)
        let deadline = Date().addingTimeInterval(Motion.fadeDuration * 2)
        while Date() < deadline { RunLoop.main.run(mode: .default, before: deadline) }

        XCTAssertFalse(field.isHidden, "the leaving fade's completion must not hide a field that came back")
    }
}
