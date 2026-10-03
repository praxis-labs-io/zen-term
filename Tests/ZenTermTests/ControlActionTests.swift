import AppKit
import ControlProtocol
import TerminalKit
import XCTest

@testable import ZenTerm

final class ControlActionTests: WindowTestCase {
    private var originalOverride: (() -> TerminalSurface)?
    private var originalConfig: GeneralConfig!
    private var controllers: [WindowController] = []
    private let originalPresence = WindowController.isPresent

    override func setUpWithError() throws {
        try super.setUpWithError()
        WindowController.isPresent = { _ in true }
        originalOverride = TerminalSurfaceFactory.makeOverride
        originalConfig = GeneralConfig.current
        Motion.isReduceMotionEnabled = { true }
        TerminalSurfaceFactory.makeOverride = { RecordingSurface() }
        GeneralConfig.setCurrentForTesting(.builtIn)
        SidebarController.resetLastChoiceForTesting()
    }

    override func tearDownWithError() throws {
        for c in controllers {
            c.windowWillClose(Notification(name: NSWindow.willCloseNotification))
            AttentionCenter.shared.forget(windowID: c.windowID)
        }
        controllers = []
        SidebarController.resetLastChoiceForTesting()
        TerminalSurfaceFactory.makeOverride = originalOverride
        GeneralConfig.setCurrentForTesting(originalConfig)
        WindowController.isPresent = originalPresence
        try super.tearDownWithError()
    }

    private func makeWindow() -> WindowController {
        let c = WindowController(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            initialCWD: FileManager.default.temporaryDirectory)
        c.mountAndStart()
        controllers.append(c)
        return c
    }

    private func run(_ name: String?, in key: WindowController?) throws -> ControlReply {
        var responder = ControlResponder(
            windows: { [unowned self] in controllers }, keyWindow: { key })
        responder.runAction = { key?.handle($0) }
        var reply: ControlReply?
        responder.respond(to: ControlRequest(id: 1, cmd: .action, args: ControlArgs(name: name))) { reply = $0 }
        return try XCTUnwrap(reply, "action never answered")
    }

    private struct AnsweredOK: Error {}

    private func error(_ reply: ControlReply) throws -> ControlError {
        guard case .failure(let error) = reply else {
            XCTFail("expected an error, got \(reply)")
            throw AnsweredOK()
        }
        return error
    }

    private func paneCount(_ c: WindowController) -> Int {
        c.listing().workspaces[0].tabs[0].panes.count
    }

    func test_aNamedActionRunsInTheKeyWindow() throws {
        let key = makeWindow()
        let other = makeWindow()
        XCTAssertTrue(key.sidebarForTesting.isDocked)

        XCTAssertNoThrow(try run("toggle_sidebar", in: key).get())
        XCTAssertNoThrow(try run("split_vertical", in: key).get())

        XCTAssertFalse(key.sidebarForTesting.isDocked)
        XCTAssertEqual(paneCount(key), 2)
        XCTAssertTrue(other.sidebarForTesting.isDocked, "only the key window takes the action")
        XCTAssertEqual(paneCount(other), 1)
    }

    func test_anAliasIsAccepted() throws {
        XCTAssertNoThrow(try run("toggle_zoom", in: makeWindow()).get())
    }

    func test_withSettingsOpenAnActionDoesWhatItsShortcutDoesThere() throws {
        let key = makeWindow()
        key.handle(.openSettings)
        XCTAssertTrue(key.isModalOverlayOpen)

        XCTAssertNoThrow(try run("split_vertical", in: key).get())
        XCTAssertEqual(paneCount(key), 1, "a split is held back while a card is open, as the shortcut is")
        XCTAssertTrue(key.isModalOverlayOpen)

        XCTAssertNoThrow(try run("toggle_sidebar", in: key).get())
        XCTAssertFalse(key.sidebarForTesting.isDocked, "the sidebar toggles over Settings, as the shortcut does")
        XCTAssertTrue(key.isModalOverlayOpen)

        XCTAssertNoThrow(try run("open_settings", in: key).get())
        XCTAssertFalse(key.isModalOverlayOpen, "Settings' own shortcut closes it")
    }

    func test_anUnknownNameIsNotFoundAndListsTheActions() throws {
        let key = makeWindow()

        let unknown = try error(run("explode", in: key))

        XCTAssertEqual(unknown.code, .notFound)
        XCTAssertTrue(unknown.message.hasPrefix("There is no action named explode."), unknown.message)
        for name in ["split_vertical", "toggle_sidebar", "select_tab_9", "toggle_float:scratch", "next_waiting_agent"] {
            XCTAssertTrue(unknown.message.contains(name), "\(name) is missing from: \(unknown.message)")
        }
        XCTAssertFalse(unknown.message.contains("toggle_zoom"), "aliases stay out of the list")
    }

    func test_aFloatThatIsNotConfiguredIsNotFound() throws {
        let key = makeWindow()

        XCTAssertEqual(try error(run("toggle_float:nope", in: key)).code, .notFound)
    }

    func test_aMissingNameIsABadRequestAndNoWindowIsNotFound() throws {
        XCTAssertEqual(try error(run(nil, in: makeWindow())).code, .badRequest)
        XCTAssertEqual(try error(run("toggle_sidebar", in: nil)).code, .notFound)
    }

    func test_everyActionTheSettingsTestsKnowIsListed() {
        let listed = Set(KeyInterceptor.ReservedChord.everyAction.map(\.actionToken))
        let known = SettingsKeybindGroupsTests.everyAction.map(\.actionToken).filter { $0 != "toggle_float:btop" }

        XCTAssertEqual(Set(known).subtracting(listed), [])
        XCTAssertEqual(listed.count, KeyInterceptor.ReservedChord.everyAction.count, "a name is listed twice")
    }
}
