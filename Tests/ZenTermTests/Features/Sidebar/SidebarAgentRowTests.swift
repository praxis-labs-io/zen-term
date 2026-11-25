import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

final class SidebarAgentRowTests: WindowTestCase {
    private var originalTheme: AppTheme!
    private var tempRoots: [URL] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        originalTheme = Theme.current
    }

    override func tearDownWithError() throws {
        Theme.setCurrentForTesting(originalTheme)
        for dir in tempRoots { try? FileManager.default.removeItem(at: dir) }
        tempRoots = []
        try super.tearDownWithError()
    }

    private func makeThemeWithYellow(_ hex: String) throws -> AppTheme {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenterm-agent-row-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempRoots.append(dir)
        try """
        background = #010101
        foreground = #fefefe
        palette = \(AccentSlot.yellow.ansiIndex)=\(hex)
        """.write(to: dir.appendingPathComponent("theme"), atomically: true, encoding: .utf8)
        return ConfigLoader.loadAppTheme(configRoot: dir, general: .builtIn)
    }

    private func spinnerColor(of row: NSView) throws -> NSColor? {
        let spinner = try XCTUnwrap(descendants(row).compactMap { $0 as? Spinner }.first)
        return spinner.arcForTesting.strokeColor.flatMap(NSColor.init)
    }

    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }

    private func summaryLabel(of row: NSView, saying text: String) throws -> NSTextField {
        return try XCTUnwrap(descendants(row).compactMap { $0 as? NSTextField }.first { $0.stringValue == text })
    }

    func test_theSummary_takesNormalInk_leavingTheStateToTheDot() throws {
        let row = SidebarAgentRow {}
        for state in [AttentionTone.blocked, .done, .working, .idle] {
            row.render(
                SidebarAgentItem(
                    id: SurfaceID(raw: 1), state: state, summary: state.accessibilityName, detail: "zen-term",
                    message: nil))

            XCTAssertEqual(
                try summaryLabel(of: row, saying: state.accessibilityName).textColor, Theme.current.chrome.ink(.normal),
                "a \(state.accessibilityName) agent's summary takes a state color")
        }
    }

    func test_aWorkingAgentsSpinner_drawsInTheWorkingRole_acrossAThemeSwitch() throws {
        let row = SidebarAgentRow {}
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 80), styleMask: [.borderless],
            backing: .buffered, defer: false)
        window.contentView?.addSubview(row)
        row.render(
            SidebarAgentItem(
                id: SurfaceID(raw: 1), state: .working, summary: "Working", detail: "zen-term", message: nil))

        XCTAssertEqual(try spinnerColor(of: row), Theme.current.chrome.working.nsColor)
        XCTAssertNotEqual(Theme.current.chrome.working, Theme.current.chrome.accent)

        Theme.setCurrentForTesting(try makeThemeWithYellow("#ffaa00"))
        row.reapplyThemeTree()

        let yellow = try XCTUnwrap(TerminalColor(hex: "#ffaa00")).nsColor
        XCTAssertEqual(try spinnerColor(of: row), yellow)
    }

    func test_theDotsAndTheSpinner_centerOnTheTitleLine() throws {
        let row = SidebarAgentRow {}
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 80), styleMask: [.borderless],
            backing: .buffered, defer: false)
        let content = try XCTUnwrap(window.contentView)
        content.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            row.topAnchor.constraint(equalTo: content.topAnchor),
        ])
        func midY(_ view: NSView) -> CGFloat { view.convert(view.bounds, to: nil).midY }

        for state in [AttentionTone.blocked, .done, .working, .idle] {
            row.render(
                SidebarAgentItem(
                    id: SurfaceID(raw: 1), state: state, summary: state.accessibilityName, detail: "zen-term",
                    message: nil))
            row.reapplyThemeTree()
            content.layoutSubtreeIfNeeded()

            let title = try summaryLabel(of: row, saying: state.accessibilityName)
            let glyph: NSView =
                state == .working
                ? try XCTUnwrap(descendants(row).compactMap { $0 as? Spinner }.first) : row.dotForTesting
            XCTAssertEqual(
                midY(glyph), midY(title), accuracy: 0.5,
                "a \(state.accessibilityName) agent's glyph centers on the title's line")
        }
        XCTAssertNotEqual(
            midY(try summaryLabel(of: row, saying: "Idle")), midY(row), accuracy: 0.5,
            "the title sits above the row's middle, or this test proves nothing")
    }

    func test_anAgentsChipSitsOnTheTitleLine_withTheWorkspaceLineStillUnderIt() throws {
        let row = SidebarAgentRow {}
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 80), styleMask: [.borderless],
            backing: .buffered, defer: false)
        let content = try XCTUnwrap(window.contentView)
        content.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            row.topAnchor.constraint(equalTo: content.topAnchor),
        ])
        row.render(
            SidebarAgentItem(
                id: SurfaceID(raw: 1), state: .idle, summary: "Review x.swift", detail: "zen-term", message: nil,
                process: ProcessIcon.forAgent("claude")))
        content.layoutSubtreeIfNeeded()
        func frame(_ view: NSView) -> NSRect { view.convert(view.bounds, to: nil) }

        let mark = try XCTUnwrap(row.processBadgeForTesting, "the row draws no chip")
        XCTAssertTrue(descendants(row).contains { $0 === mark }, "the chip is not in the row")
        XCTAssertEqual(mark.process?.name, "Claude Code")
        let title = try summaryLabel(of: row, saying: "Review x.swift")
        let workspace = try summaryLabel(of: row, saying: "zen-term")
        XCTAssertFalse(mark.isHiddenOrHasHiddenAncestor)
        XCTAssertFalse(workspace.isHiddenOrHasHiddenAncestor)
        XCTAssertGreaterThan(frame(mark).width, 0)
        XCTAssertGreaterThan(frame(workspace).width, 0)
        XCTAssertEqual(frame(mark).midY, frame(title).midY, accuracy: 0.5, "the chip centers on the title's line")
        XCTAssertLessThan(frame(workspace).maxY, frame(title).minY, "the workspace line sits under the title")
        XCTAssertEqual(
            frame(workspace).minX, frame(title).minX, accuracy: 0.5, "the workspace line starts with the title's text")
    }
}
