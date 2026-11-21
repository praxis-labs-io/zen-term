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

    private func spinnerColors(of row: NSView) throws -> [NSColor] {
        let spinner = try XCTUnwrap(descendants(row).compactMap { $0 as? Spinner }.first)
        return (spinner.layer?.sublayers ?? []).compactMap(\.backgroundColor).compactMap { NSColor(cgColor: $0) }
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
                    id: SurfaceID(raw: 1), state: state, summary: state.summary, detail: "zen-term", message: nil))

            XCTAssertEqual(
                try summaryLabel(of: row, saying: state.summary).textColor, Theme.current.chrome.ink(.normal),
                "a \(state.summary) agent's summary takes a state color")
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

        let before = try spinnerColors(of: row)
        XCTAssertEqual(before.count, 6)
        XCTAssertTrue(before.allSatisfy { $0 == Theme.current.chrome.working.nsColor })
        XCTAssertNotEqual(Theme.current.chrome.working, Theme.current.chrome.accent)

        Theme.setCurrentForTesting(try makeThemeWithYellow("#ffaa00"))
        row.reapplyThemeTree()

        let yellow = try XCTUnwrap(TerminalColor(hex: "#ffaa00")).nsColor
        let after = try spinnerColors(of: row)
        XCTAssertTrue(after.allSatisfy { $0 == yellow }, "\(after)")
    }

    func test_aDot_centersOnTheTitleLine_andTheSpinnerOnTheRow() throws {
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

        for state in [AttentionTone.blocked, .done, .working] {
            row.render(
                SidebarAgentItem(
                    id: SurfaceID(raw: 1), state: state, summary: state.summary, detail: "zen-term", message: nil))
            row.reapplyThemeTree()
            content.layoutSubtreeIfNeeded()

            let title = try summaryLabel(of: row, saying: state.summary)
            if state == .working {
                let spinner = try XCTUnwrap(descendants(row).compactMap { $0 as? Spinner }.first)
                XCTAssertEqual(midY(spinner), midY(row), accuracy: 0.5, "the spinner centers on the row")
            } else {
                XCTAssertEqual(
                    midY(row.dotForTesting), midY(title), accuracy: 0.5,
                    "a \(state.summary) dot centers on the title's line")
            }
        }
        XCTAssertNotEqual(
            midY(try summaryLabel(of: row, saying: "Working")), midY(row), accuracy: 0.5,
            "the title sits above the row's middle, or this test proves nothing")
    }
}
