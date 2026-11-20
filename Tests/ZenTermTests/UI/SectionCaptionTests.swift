import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

final class SectionCaptionTests: WindowTestCase {
    private var originalTheme: AppTheme!

    override func setUp() {
        super.setUp()
        originalTheme = Theme.current
    }

    override func tearDownWithError() throws {
        Theme.setCurrentForTesting(originalTheme)
        try super.tearDownWithError()
    }

    private func runs(_ caption: SectionCaption) -> [[NSAttributedString.Key: Any]] {
        var result: [[NSAttributedString.Key: Any]] = []
        let string = caption.attributedStringValue
        string.enumerateAttributes(in: NSRange(location: 0, length: string.length)) { attributes, _, _ in
            result.append(attributes)
        }
        return result
    }

    func test_themeWalk_recolorsTheCaptionAndItsRequiredMarker() throws {
        let caption = SectionCaption("Name", required: true)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 60), styleMask: [.borderless],
            backing: .buffered, defer: false)
        window.contentView?.addSubview(caption)
        XCTAssertEqual(runs(caption).count, 2, "premise: the label and the marker are separate runs")

        var dimmed = Theme.zenInk
        dimmed.foreground = try XCTUnwrap(TerminalColor(hex: "#575279"))
        Theme.setCurrentForTesting(AppTheme(terminal: dimmed))
        XCTAssertNotEqual(
            runs(caption).first?[.foregroundColor] as? NSColor, Theme.current.chrome.ink(.muted),
            "premise: the theme change moves the muted ink")
        window.contentView?.reapplyThemeTree()

        for run in runs(caption) {
            XCTAssertEqual(run[.foregroundColor] as? NSColor, Theme.current.chrome.ink(.muted))
        }
        XCTAssertEqual(runs(caption).first?[.font] as? NSFont, ChromeType.sectionLabel)
    }
}
