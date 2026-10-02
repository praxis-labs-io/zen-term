import AppKit
import ControlProtocol
import TabKit
import TerminalKit
import XCTest

@testable import ZenTerm

final class ControlPaneTests: WindowTestCase {
    private var originalOverride: (() -> TerminalSurface)?
    private var originalConfig: GeneralConfig!
    private var controllers: [WindowController] = []
    private var spawned: [RecordingSurface] = []
    private var raised: [WindowController] = []
    private let originalPresence = WindowController.isPresent

    override func setUpWithError() throws {
        try super.setUpWithError()
        WindowController.isPresent = { _ in true }
        originalOverride = TerminalSurfaceFactory.makeOverride
        originalConfig = GeneralConfig.current
        Motion.isReduceMotionEnabled = { true }
        TerminalSurfaceFactory.makeOverride = { [weak self] in
            let surface = RecordingSurface()
            self?.spawned.append(surface)
            return surface
        }
        GeneralConfig.setCurrentForTesting(.builtIn)
    }

    override func tearDownWithError() throws {
        for c in controllers {
            c.windowWillClose(Notification(name: NSWindow.willCloseNotification))
            AttentionCenter.shared.forget(windowID: c.windowID)
        }
        controllers = []
        spawned = []
        TerminalSurfaceFactory.makeOverride = originalOverride
        GeneralConfig.setCurrentForTesting(originalConfig)
        WindowController.isPresent = originalPresence
        try super.tearDownWithError()
    }

    private func makeWindow() -> WindowController {
        let c = WindowController(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            initialCWD: FileManager.default.temporaryDirectory)
        c.mountAndStart()
        c.window.contentView?.layoutSubtreeIfNeeded()
        controllers.append(c)
        return c
    }

    private var responder: ControlResponder {
        var responder = ControlResponder(
            windows: { [unowned self] in controllers }, keyWindow: { [unowned self] in controllers.first })
        responder.bringForward = { [unowned self] in raised.append($0) }
        return responder
    }

    private func send(_ cmd: ControlCommand, _ args: ControlArgs = ControlArgs(), from pane: Int? = nil) throws
        -> ControlReply
    {
        var reply: ControlReply?
        responder.respond(
            to: ControlRequest(id: 1, cmd: cmd, args: args, caller: pane.map(ControlCaller.init(pane:)))
        ) { reply = $0 }
        return try XCTUnwrap(reply, "\(cmd.rawValue) never answered")
    }

    private func result<P>(_ reply: ControlReply, as: P.Type) throws -> P {
        try XCTUnwrap(try reply.get() as? P, "\(reply)")
    }

    private struct AnsweredOK: Error {}

    private func error(_ reply: ControlReply) throws -> ControlError {
        guard case .failure(let error) = reply else {
            XCTFail("expected an error, got \(reply)")
            throw AnsweredOK()
        }
        return error
    }

    private func token(of surface: RecordingSurface) throws -> Int {
        try XCTUnwrap(surface.lastConfig?.environment["ZEN_PANE"].flatMap(Int.init))
    }

    private func surface(_ token: Int) throws -> RecordingSurface {
        try XCTUnwrap(spawned.first { (try? self.token(of: $0)) == token })
    }

    private func panes(_ c: WindowController) -> [ListResult.Pane] {
        c.listing().workspaces.flatMap(\.tabs).filter(\.active).flatMap(\.panes)
    }

    func test_splitFromAPaneLaunchesTheCommandBesideItAndLeavesFocusWhereItWas() throws {
        let c = makeWindow()
        let caller = try XCTUnwrap(spawned.first)
        let callerToken = try token(of: caller)
        XCTAssertTrue(c.window.firstResponder === caller.view)

        let opened = try result(
            send(.paneSplit, ControlArgs(cmd: "htop", dir: .right), from: callerToken), as: PaneResult.self)

        let new = try surface(opened.pane)
        XCTAssertTrue(new.lastConfig?.args.last?.hasPrefix("htop;") == true, "\(String(describing: new.lastConfig))")
        XCTAssertEqual(panes(c).map(\.token), [callerToken, opened.pane])
        XCTAssertTrue(c.focusedSurfaceForTesting === caller)
        XCTAssertTrue(c.window.firstResponder === caller.view, "the rebuild dropped the caller's keyboard focus")
        XCTAssertTrue(raised.isEmpty)
    }

    func test_splitWithFocusMovesFocusToTheNewPane() throws {
        let c = makeWindow()
        let caller = try token(of: XCTUnwrap(spawned.first))

        let opened = try result(
            send(.paneSplit, ControlArgs(focus: true, dir: .down), from: caller), as: PaneResult.self)

        let new = try surface(opened.pane)
        XCTAssertTrue(c.focusedSurfaceForTesting === new)
        XCTAssertTrue(c.window.firstResponder === new.view)
        XCTAssertNil(new.lastConfig?.args.first { $0.contains(";") }, "a split without cmd runs a shell")
    }

    func test_splitWithAnAgentCommandIdentifiesTheAgentInList() throws {
        let c = makeWindow()
        let caller = try token(of: XCTUnwrap(spawned.first))

        let opened = try result(
            send(.paneSplit, ControlArgs(cmd: "claude", dir: .right), from: caller), as: PaneResult.self)

        XCTAssertEqual(panes(c).first { $0.token == opened.pane }?.agent?.name, "claude")
    }

    func test_splitInFocusModeIsRefusedAndOpensNothing() throws {
        let c = makeWindow()
        let caller = try token(of: XCTUnwrap(spawned.first))
        c.handle(.splitVertical)
        c.handle(.toggleZoom)
        let before = panes(c).count

        let refusal = try error(send(.paneSplit, ControlArgs(dir: .right), from: caller))

        XCTAssertEqual(refusal.code, .refused)
        XCTAssertTrue(refusal.message.contains("Focus Mode"), refusal.message)
        XCTAssertEqual(panes(c).count, before)
    }

    func test_splitNeedsADirectionAndRefusesADrawer() throws {
        let c = makeWindow()
        let caller = try token(of: XCTUnwrap(spawned.first))
        c.handle(.toggleBottomDrawer)
        let drawer = try token(of: XCTUnwrap(spawned.last))

        XCTAssertEqual(try error(send(.paneSplit, from: caller)).code, .badRequest)
        XCTAssertEqual(try error(send(.paneSplit, ControlArgs(pane: drawer, dir: .right))).code, .badRequest)
        XCTAssertEqual(try error(send(.paneSplit, ControlArgs(pane: 9999, dir: .right))).code, .notFound)
    }

    func test_focusRevealsAPaneInABackgroundTab() throws {
        let c = makeWindow()
        let first = try XCTUnwrap(c.activeTabIDForTesting)
        let target = try token(of: XCTUnwrap(spawned.first))
        c.newTabForTesting()
        XCTAssertNotEqual(c.activeTabIDForTesting, first)

        XCTAssertEqual(try send(.paneFocus, ControlArgs(pane: target)).isSuccess, true)

        XCTAssertEqual(c.activeTabIDForTesting, first)
        XCTAssertTrue(c.focusedSurfaceForTesting === (try surface(target)))
    }

    func test_focusOpensAndFocusesADrawer() throws {
        let c = makeWindow()
        c.handle(.toggleBottomDrawer)
        let drawer = try XCTUnwrap(spawned.last)
        c.handle(.toggleBottomDrawer)
        let tab = try XCTUnwrap(c.controllerForTesting(tab: XCTUnwrap(c.activeTabIDForTesting)))
        tab.focusActivePane()
        XCTAssertFalse(tab.overlayState.isBottomOpen)

        XCTAssertEqual(try send(.paneFocus, ControlArgs(pane: token(of: drawer))).isSuccess, true)

        XCTAssertTrue(tab.overlayState.isBottomOpen)
        XCTAssertTrue(c.window.firstResponder === drawer.view)
    }

    func test_closeRefusesABusyPaneWithoutForce() throws {
        let c = makeWindow()
        let caller = try token(of: XCTUnwrap(spawned.first))
        let opened = try result(send(.paneSplit, ControlArgs(dir: .right), from: caller), as: PaneResult.self)
        let busy = try surface(opened.pane)
        busy.isBusy = true
        busy.title = "htop"

        let refusal = try error(send(.paneClose, ControlArgs(pane: opened.pane)))

        XCTAssertEqual(refusal.code, .refused)
        XCTAssertEqual(refusal.details?.panes.map(\.token), [opened.pane])
        XCTAssertEqual(refusal.details?.closesWindow, false)
        XCTAssertEqual(panes(c).count, 2)

        XCTAssertEqual(try send(.paneClose, ControlArgs(force: true, pane: opened.pane)).isSuccess, true)
        XCTAssertEqual(panes(c).map(\.token), [caller])
        XCTAssertTrue(busy.terminated)
    }

    func test_closingAnIdlePaneKeepsFocusOnTheCaller() throws {
        let c = makeWindow()
        let caller = try XCTUnwrap(spawned.first)
        let opened = try result(
            send(.paneSplit, ControlArgs(dir: .right), from: token(of: caller)), as: PaneResult.self)

        XCTAssertEqual(try send(.paneClose, ControlArgs(pane: opened.pane)).isSuccess, true)

        XCTAssertEqual(panes(c).map(\.token), [try token(of: caller)])
        XCTAssertTrue(c.window.firstResponder === caller.view)
    }

    func test_closingTheLastPaneClosesItsTabUnderTheTabRule() throws {
        let c = makeWindow()
        let only = try token(of: XCTUnwrap(spawned.first))

        let refusal = try error(send(.paneClose, ControlArgs(pane: only)))
        XCTAssertEqual(refusal.code, .refused)
        XCTAssertEqual(refusal.details?.closesWindow, true, "the window's last tab")

        c.newTabForTesting()
        let tabs = c.tabOrderForTesting.count
        XCTAssertEqual(try send(.paneClose, ControlArgs(pane: only)).isSuccess, true)
        XCTAssertEqual(c.tabOrderForTesting.count, tabs - 1)
    }

    func test_closeLeavesADrawerAlone() throws {
        let c = makeWindow()
        c.handle(.toggleBottomDrawer)
        let drawer = try token(of: XCTUnwrap(spawned.last))

        XCTAssertEqual(try error(send(.paneClose, ControlArgs(pane: drawer))).code, .badRequest)
    }

    func test_sendPastesTheTextAndSubmitsOnceAfterIt() throws {
        _ = makeWindow()
        let target = try XCTUnwrap(spawned.first)

        XCTAssertEqual(
            try send(.paneSend, ControlArgs(text: "echo a\necho b", enter: true), from: token(of: target)).isSuccess,
            true)
        XCTAssertEqual(target.inputs, [.paste("echo a\necho b"), .submit])

        XCTAssertEqual(try send(.paneSend, ControlArgs(text: "ls"), from: token(of: target)).isSuccess, true)
        XCTAssertEqual(target.inputs.last, .paste("ls"))
        XCTAssertEqual(target.inputs.count, 3)

        XCTAssertEqual(try error(send(.paneSend, from: token(of: target))).code, .badRequest)
    }

    func test_sendReachesADrawerByItsToken() throws {
        let c = makeWindow()
        c.handle(.toggleBottomDrawer)
        let drawer = try XCTUnwrap(spawned.last)

        XCTAssertEqual(try send(.paneSend, ControlArgs(pane: token(of: drawer), text: "top")).isSuccess, true)
        XCTAssertEqual(drawer.inputs, [.paste("top")])
    }

    func test_readReturnsTheViewportWithoutTrailingBlankRows() throws {
        _ = makeWindow()
        let target = try XCTUnwrap(spawned.first)
        target.rows[12] = "   "

        let read = try result(send(.paneRead, from: token(of: target)), as: PaneText.self)

        XCTAssertEqual(read.text, target.rows[0...11].joined(separator: "\n"))
    }

    func test_readLinesReturnsTheTailIncludingScrollback() throws {
        _ = makeWindow()
        let target = try XCTUnwrap(spawned.first)
        target.scrollback = (1...5000).map(String.init)
        target.rows = []

        let read = try result(send(.paneRead, ControlArgs(lines: 100), from: token(of: target)), as: PaneText.self)

        XCTAssertEqual(read.text, (4901...5000).map(String.init).joined(separator: "\n"))
        XCTAssertEqual(try error(send(.paneRead, ControlArgs(lines: 0), from: token(of: target))).code, .badRequest)
    }

    func test_withoutACallerAPaneCommandActsOnTheKeyWindowsFocusedPane() throws {
        _ = makeWindow()
        let focused = try XCTUnwrap(spawned.first)

        XCTAssertEqual(try send(.paneSend, ControlArgs(text: "pwd")).isSuccess, true)

        XCTAssertEqual(focused.inputs, [.paste("pwd")])
    }
}

private extension Result {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}
