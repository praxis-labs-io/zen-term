import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

/// How ⌘⇧P gets on screen now that the `workspaces` file is read off the main thread (ZEN-275).
///
/// The card is built once the workspaces are in hand rather than presented empty and filled: a card
/// that springs in at one size and resizes a frame later reads as a flash. That makes the press and
/// the card two separate turns of the main queue, which is the shape that needs pinning — nothing
/// may present twice, and a load landing after the user changed their mind may not present at all.
@MainActor
final class RepoPickerPresentationTests: XCTestCase {
    private var originalOverride: (() -> TerminalSurface)?
    private var originalConfig: GeneralConfig!
    private var controller: WindowController?
    private var tempRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        originalOverride = TerminalSurfaceFactory.makeOverride
        originalConfig = GeneralConfig.current
        Motion.isReduceMotionEnabled = { true }
        TerminalSurfaceFactory.makeOverride = { RecordingSurface() }
        GeneralConfig.setCurrentForTesting(.builtIn)
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenterm-picker-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        ConfigLoader.defaultRootOverrideForTesting = tempRoot
    }

    override func tearDownWithError() throws {
        controller?.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        controller = nil
        ConfigLoader.defaultRootOverrideForTesting = nil
        Motion.isReduceMotionEnabled = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
        TerminalSurfaceFactory.makeOverride = originalOverride
        GeneralConfig.setCurrentForTesting(originalConfig)
        try? FileManager.default.removeItem(at: tempRoot)
        try super.tearDownWithError()
    }

    private func seedWorkspaces(_ text: String) throws {
        try text.write(to: tempRoot.appendingPathComponent("workspaces"), atomically: true, encoding: .utf8)
    }

    private func makeWindow() -> WindowController {
        let c = WindowController(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            initialCWD: FileManager.default.temporaryDirectory)
        c.showAndStart()
        controller = c
        return c
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func pickers(in c: WindowController) -> [RepoPickerOverlay] {
        descendants(of: c.window.contentView!).compactMap { $0 as? RepoPickerOverlay }
    }

    private func workspaceRows(in picker: RepoPickerOverlay) -> [SelectableRowView] {
        picker.rowViews.compactMap { $0 as? SelectableRowView }
    }

    private let twoWorkspaces = """
        [Alpha]
        path = ~/Dev/alpha

        [Beta]
        path = ~/Dev/beta
        """

    /// The card must arrive already holding its rows. Presenting first and filling after is what
    /// made the open flash: the list height is what sizes the card, so entries landing a frame later
    /// resize it mid-spring.
    func test_picker_isPresentedWithItsRowsAlreadyIn() throws {
        try seedWorkspaces(twoWorkspaces)
        let c = makeWindow()

        c.handle(.toggleRepoPicker)

        waitUntil(!pickers(in: c).isEmpty, "the picker to be presented")
        let picker = try XCTUnwrap(pickers(in: c).first)
        XCTAssertEqual(
            workspaceRows(in: picker).count, 3,
            "the ＋ row and a row per workspace, all present when the card first appears")
    }

    /// The press and the card are separate turns now, so a second press lands while nothing is on
    /// screen. It has to read as the toggle it is rather than starting a second card.
    func test_secondPressBeforeTheCardArrives_leavesNoPicker() throws {
        try seedWorkspaces(twoWorkspaces)
        let c = makeWindow()

        c.handle(.toggleRepoPicker)
        c.handle(.toggleRepoPicker)  // pressed again before the load landed

        // Give the load every chance to land and present.
        let settled = expectation(description: "the load had time to land")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { settled.fulfill() }
        wait(for: [settled], timeout: 2)

        XCTAssertTrue(pickers(in: c).isEmpty, "press-press is open-then-close, not two cards")
        XCTAssertFalse(c.isModalOverlayOpen)
    }

    /// Esc between the press and the card means the user changed their mind before anything was
    /// drawn. The load landing afterwards must not put a card up.
    func test_escapeBeforeTheCardArrives_stopsItFromAppearing() throws {
        try seedWorkspaces(twoWorkspaces)
        let c = makeWindow()

        c.handle(.toggleRepoPicker)
        c.handle(.toggleCommandPalette)  // any other card closes the pending one on its way up

        let settled = expectation(description: "the load had time to land")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { settled.fulfill() }
        wait(for: [settled], timeout: 2)

        XCTAssertTrue(pickers(in: c).isEmpty, "the picker the user moved on from must not arrive")
        XCTAssertFalse(
            descendants(of: c.window.contentView!).compactMap { $0 as? CommandPaletteOverlay }.isEmpty,
            "the card they did ask for is the one that's up")
    }
}
