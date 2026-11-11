import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

@MainActor
final class WorkspaceRenameTests: WindowTestCase {
    private var originalOverride: (() -> TerminalSurface)?
    private var originalConfig: GeneralConfig!
    private var controllers: [WindowController] = []
    private var root = FileManager.default.temporaryDirectory

    override func setUpWithError() throws {
        try super.setUpWithError()
        originalOverride = TerminalSurfaceFactory.makeOverride
        originalConfig = GeneralConfig.current
        GeneralConfig.setCurrentForTesting(GeneralConfig.builtIn)
        Motion.isReduceMotionEnabled = { true }
        TerminalSurfaceFactory.makeOverride = { RecordingSurface() }
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenterm-wsrename-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for controller in controllers {
            controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        }
        controllers = []
        TerminalSurfaceFactory.makeOverride = originalOverride
        GeneralConfig.setCurrentForTesting(originalConfig)
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    private func makeWindow() -> WindowController {
        let controller = WindowController(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), initialCWD: root)
        controller.mountAndStart()
        controllers.append(controller)
        return controller
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func renameCard(_ controller: WindowController) -> RenameOverlay? {
        descendants(of: controller.window.contentView!).compactMap { $0 as? RenameOverlay }.first
    }

    private func sidebarTitles(_ controller: WindowController) -> [String] {
        controller.sidebarForTesting.view.rowsForTesting.map(\.titleForTesting)
    }

    private func rename(_ controller: WindowController, to name: String) throws {
        controller.handle(.renameWorkspace)
        let card = try XCTUnwrap(renameCard(controller), "the rename card should be up")
        card.nameFieldForTesting.setText(name)
        try XCTUnwrap(card.nameFieldForTesting.onEnter)()
    }

    func test_theChord_opensTheCardSeededWithTheNameOverTheGivenName() throws {
        let controller = makeWindow()
        try rename(controller, to: "api")

        controller.handle(.renameWorkspace)

        let card = try XCTUnwrap(renameCard(controller))
        XCTAssertEqual(
            descendants(of: card).compactMap { ($0 as? ModalHeader) }.flatMap { descendants(of: $0) }
                .compactMap { ($0 as? NSTextField)?.stringValue },
            ["Rename Workspace"])
        XCTAssertEqual(card.nameFieldForTesting.text, "api")
        XCTAssertEqual(card.nameFieldForTesting.placeholder, "Workspace 1", "the given name, as the reset hint")
    }

    func test_committing_renamesTheWindowTitleAndTheSidebarRow() throws {
        let controller = makeWindow()
        controller.openWorkspaceForTesting(Workspace(title: "Alpha", path: root, tabs: [.init()], env: [:]))
        XCTAssertEqual(sidebarTitles(controller), ["Workspace 1", "Alpha"])

        try rename(controller, to: "api")

        XCTAssertEqual(controller.window.title, "api")
        XCTAssertEqual(sidebarTitles(controller), ["Workspace 1", "api"])
        XCTAssertNil(renameCard(controller), "the card closes on commit")
    }

    func test_theVerbAlone_rendersTheNewName_withNoCardInvolved() throws {
        let controller = makeWindow()
        let background = controller.activeWorkspaceIDForTesting
        controller.openWorkspaceForTesting(Workspace(title: "Alpha", path: root, tabs: [.init()], env: [:]))

        XCTAssertTrue(controller.renameWorkspace(background, to: "api"))
        XCTAssertTrue(controller.renameWorkspace(controller.activeWorkspaceIDForTesting, to: "web"))

        XCTAssertEqual(sidebarTitles(controller), ["api", "web"])
        XCTAssertEqual(controller.window.title, "web")
    }

    func test_anEmptyName_restoresTheGivenName_unconfiguredAndConfigured() throws {
        let controller = makeWindow()
        try rename(controller, to: "api")
        try rename(controller, to: "   ")
        XCTAssertEqual(controller.window.title, "Workspace 1")

        controller.openWorkspaceForTesting(Workspace(title: "Alpha", path: root, tabs: [.init()], env: [:]))
        try rename(controller, to: "api")
        try rename(controller, to: "")

        XCTAssertEqual(controller.window.title, "Alpha")
        XCTAssertEqual(sidebarTitles(controller), ["Workspace 1", "Alpha"])
    }

    func test_theChord_togglesTheCardClosed() throws {
        let controller = makeWindow()
        controller.handle(.renameWorkspace)
        XCTAssertNotNil(renameCard(controller))

        controller.handle(.renameWorkspace)

        XCTAssertFalse(controller.isModalOverlayOpen)
        XCTAssertEqual(controller.window.title, "Workspace 1", "closing is not committing")
    }

    func test_renamingWorkspaceOne_freesItsNumberForTheNextNewWorkspace() throws {
        let controller = makeWindow()
        try rename(controller, to: "api")

        controller.handle(.newWorkspace)

        XCTAssertEqual(sidebarTitles(controller), ["api", "Workspace 1"])
    }
}
