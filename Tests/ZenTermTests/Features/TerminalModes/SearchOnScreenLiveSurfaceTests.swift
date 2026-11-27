import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

@MainActor
final class SearchOnScreenLiveSurfaceTests: WindowTestCase {
    private var originalOverride: (() -> TerminalSurface)?
    private var originalConfig: GeneralConfig!
    private var controller: WindowController?
    private var surfaces: [GhosttySurface] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        originalOverride = TerminalSurfaceFactory.makeOverride
        originalConfig = GeneralConfig.current
        var config = GeneralConfig.builtIn
        config.shell = "/bin/zsh"
        GeneralConfig.setCurrentForTesting(config)
        Motion.isReduceMotionEnabled = { true }
        TerminalSurfaceFactory.makeOverride = { [weak self] in
            let surface = GhosttySurface()
            self?.surfaces.append(surface)
            return surface
        }
    }

    override func tearDownWithError() throws {
        controller?.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        controller = nil
        surfaces.forEach { $0.terminate() }
        surfaces = []
        TerminalSurfaceFactory.makeOverride = originalOverride
        GeneralConfig.setCurrentForTesting(originalConfig)
        try super.tearDownWithError()
    }

    private func shellPane() throws -> (WindowController, GhosttySurface, TerminalGrid) {
        let c = WindowController(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            initialCWD: FileManager.default.temporaryDirectory)
        c.mountAndStart()
        c.window.orderFront(nil)
        c.window.contentView?.layoutSubtreeIfNeeded()
        controller = c
        let surface = try XCTUnwrap(surfaces.first)
        try XCTSkipIf(!surface.isStarted, "ghostty_surface_new failed")
        waitUntil(
            surface.foregroundProcessGroupID.map { ForegroundGroup.isShell($0) } == true
                && !(surface.activeScreenText ?? "").allSatisfy(\.isWhitespace),
            "the shell's first prompt", timeout: 15)
        return (c, surface, try XCTUnwrap(surface.grid))
    }

    private func text(of row: TerminalGridRow?) -> String {
        (row?.cells.map { $0.text.isEmpty && $0.width > 0 ? " " : $0.text }.joined() ?? "")
            .trimmingCharacters(in: .whitespaces)
    }

    private func lastRow(_ grid: TerminalGrid, where matches: (TerminalGridRow) -> Bool) -> Int? {
        (0..<grid.rowCount).last { grid.row($0).map(matches) ?? false }
    }

    func test_aNeedleWrappedAcrossTwoVisibleRowsCountsAsOnScreen() throws {
        let (controller, surface, grid) = try shellPane()
        let columns = try settledColumns(surface, grid)
        surface.paste("printf '%*s%s%s\\n' \(columns - 3) '' zqx jwk; seq 1 100; printf '%s%s\\n' zqx jwk")
        surface.submit()
        waitUntil(lastRow(grid) { self.text(of: $0) == "zqxjwk" } != nil, "the newer match", timeout: 15)
        let wrapped = try XCTUnwrap(
            lastRow(grid) { $0.wraps && self.text(of: $0).hasSuffix("zqx") }, "the needle never wrapped")
        XCTAssertEqual(text(of: grid.row(wrapped + 1)).prefix(3), "jwk")

        let top = wrapped - 2
        surface.scroll(.lines(top - grid.viewportTop))
        waitUntil(grid.viewportTop == top, "the wrapped needle scrolled into view")
        let rows = try XCTUnwrap(surface.cellMetrics?.rows)
        let newer = try XCTUnwrap(lastRow(grid) { self.text(of: $0) == "zqxjwk" })
        XCTAssertGreaterThanOrEqual(newer, top + rows, "precondition: the newer match is below the viewport")

        controller.handle(.toggleSearch)
        let field = try XCTUnwrap(controller.focusedPanelForTesting?.findFieldForTesting)
        controller.search.beginNeedleForTesting("zqxjwk")
        waitUntil(field.countTextForTesting.contains("2"), "the engine's count", timeout: 5)

        XCTAssertFalse(controller.search.didRequestSelectionForTesting, "a match on screen selects nothing")
        XCTAssertEqual(field.countTextForTesting, "2 matches")
        XCTAssertEqual(grid.viewportTop, top, "opening find never scrolls away from a match the reader sees")
    }
}
