import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

final class HintFooterTests: WindowTestCase {
    private var originalTheme: AppTheme!
    private var tempRoots: [URL] = []

    override func setUp() {
        super.setUp()
        originalTheme = Theme.current
    }

    override func tearDownWithError() throws {
        Theme.setCurrentForTesting(originalTheme)
        for dir in tempRoots { try? FileManager.default.removeItem(at: dir) }
        tempRoots = []
        try super.tearDownWithError()
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func labels(in footer: HintFooter) -> [NSTextField] {
        descendants(of: footer).compactMap { $0 as? NSTextField }
            .filter { ["Save", "Cancel"].contains($0.stringValue) }
    }

    private func alternateTheme() throws -> AppTheme {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenterm-hint-footer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempRoots.append(dir)
        try """
        background = #010101
        foreground = #fefefe
        """.write(to: dir.appendingPathComponent("theme"), atomically: true, encoding: .utf8)
        return ConfigLoader.loadAppTheme(configRoot: dir, general: .builtIn)
    }

    private func makeFooter() -> HintFooter {
        let footer = HintFooter([.init(keys: "⏎", label: "Save"), .init(keys: "⎋", label: "Cancel")])
        footer.frame = NSRect(x: 0, y: 0, width: 380, height: 80)
        footer.layoutSubtreeIfNeeded()
        return footer
    }

    func test_showsAKeycapAndLabelPerHint() {
        let footer = makeFooter()

        XCTAssertEqual(labels(in: footer).map(\.stringValue), ["Save", "Cancel"])
        XCTAssertEqual(descendants(of: footer).compactMap { $0 as? KeycapView }.map(\.shortcut), ["⏎", "⎋"])
    }

    func test_setHint_hidesAndShowsOneHint() {
        let footer = makeFooter()

        footer.setHint("Cancel", isShown: false)

        let cancel = labels(in: footer).first { $0.stringValue == "Cancel" }
        XCTAssertEqual(cancel?.isHiddenOrHasHiddenAncestor, true)
        XCTAssertEqual(labels(in: footer).first { $0.stringValue == "Save" }?.isHiddenOrHasHiddenAncestor, false)
    }

    func test_reapplyTheme_recolorsLabelsKeycapsAndHairline() throws {
        let footer = makeFooter()
        let keycap = try XCTUnwrap(descendants(of: footer).compactMap { $0 as? KeycapView }.first)
        let hairline = try XCTUnwrap(footer.subviews.first { $0.layer != nil && $0.subviews.isEmpty })
        let labelBefore = try XCTUnwrap(labels(in: footer).first?.textColor)
        let keycapBefore = try XCTUnwrap(keycap.inkForTesting)
        let hairlineBefore = hairline.layer?.backgroundColor

        Theme.setCurrentForTesting(try alternateTheme())
        footer.reapplyTheme()

        XCTAssertNotEqual(labels(in: footer).first?.textColor, labelBefore)
        XCTAssertNotEqual(keycap.inkForTesting, keycapBefore)
        XCTAssertNotEqual(hairline.layer?.backgroundColor, hairlineBefore)
    }

    func test_thePalette_showsItsHintsThroughTheSharedFooter() throws {
        let overlay = CommandPaletteOverlay(commands: { [] }, onRun: { _ in }, onDismiss: {})
        overlay.translatesAutoresizingMaskIntoConstraints = true
        overlay.frame = NSRect(x: 0, y: 0, width: 700, height: 500)
        overlay.layoutSubtreeIfNeeded()

        let footer = try XCTUnwrap(descendants(of: overlay).compactMap { $0 as? HintFooter }.first)

        let texts = descendants(of: footer).compactMap { ($0 as? NSTextField)?.stringValue }
        XCTAssertTrue(["run", "move", "close"].allSatisfy(texts.contains))
        XCTAssertEqual(footer.frame.height, ChromeMetrics.Border.width + ChromeMetrics.Height.lg)
    }
}
