import AppKit
import ControlProtocol
import TerminalKit
import XCTest

@testable import ZenTerm

@MainActor
final class HostConnectLoginTests: WindowTestCase {
    private let host = SSHHostID(alias: "devbox")
    private var originalOverride: (() -> TerminalSurface)?
    private var originalConfig: GeneralConfig!
    private let originalPresence = WindowController.isPresent
    private var controllers: [WindowController] = []
    private var spawned: [RecordingSurface] = []
    private var fake: FakeSSHWatchers!
    private var replies: [Result<AskpassAnswer, ControlError>] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        originalOverride = TerminalSurfaceFactory.makeOverride
        originalConfig = GeneralConfig.current
        Motion.isReduceMotionEnabled = { true }
        TerminalSurfaceFactory.makeOverride = { [weak self] in
            let surface = RecordingSurface()
            self?.spawned.append(surface)
            return surface
        }
        WindowController.isPresent = { _ in true }
        var config = GeneralConfig.builtIn
        config.sshHosts = [SSHHostEntry(alias: host.alias)]
        GeneralConfig.setCurrentForTesting(config)
        fake = FakeSSHWatchers()
        SSHConnection.watchersOverrideForTesting = fake.watchers
        SSHConnection.askpassProgramOverrideForTesting = .some(URL(fileURLWithPath: "/tmp/zen"))
    }

    override func tearDownWithError() throws {
        for controller in controllers {
            controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
            AttentionCenter.shared.forget(windowID: controller.windowID)
        }
        controllers = []
        spawned = []
        SSHConnection.watchersOverrideForTesting = nil
        SSHConnection.askpassProgramOverrideForTesting = nil
        SSHHostStatusCenter.shared.setConnected(false, host: host)
        TerminalSurfaceFactory.makeOverride = originalOverride
        GeneralConfig.setCurrentForTesting(originalConfig)
        WindowController.isPresent = originalPresence
        try super.tearDownWithError()
    }

    private func makeWindow() -> WindowController {
        let c = WindowController(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), initialCWD: nil)
        controllers.append(c)
        c.mountAndStart()
        c.window.makeKeyAndOrderFront(nil)
        c.window.contentView?.layoutSubtreeIfNeeded()
        return c
    }

    private func loggingIn() throws -> (WindowController, login: RecordingSurface) {
        let c = makeWindow()
        c.selectHostForTesting(host)
        c.window.contentView?.layoutSubtreeIfNeeded()
        spawned = []
        try send(keyCode: 36, "\r", in: c)
        fake.ready?()
        c.window.contentView?.layoutSubtreeIfNeeded()
        return (c, try XCTUnwrap(spawned.first, "connecting must spawn the login pane"))
    }

    private func send(keyCode: UInt16, _ characters: String, in c: WindowController) throws {
        let event = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: c.window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
        c.window.sendEvent(event)
    }

    private func pressEscape(in c: WindowController) throws { try send(keyCode: 53, "\u{1b}", in: c) }

    private func ask(_ prompt: String, login: RecordingSurface, in c: WindowController, pid: Int = 900) throws {
        let token = try XCTUnwrap(login.lastConfig?.environment[ControlEndpoint.askpassTokenKey])
        let connection = try XCTUnwrap(c.connectionForTesting(of: host))
        XCTAssertTrue(
            connection.ask(prompt, sshPID: pid, token: token, hangup: ControlHangup()) { [weak self] in
                self?.replies.append($0)
            })
        c.window.contentView?.layoutSubtreeIfNeeded()
    }

    private func type(_ text: String, in c: WindowController) throws {
        let editor = try XCTUnwrap(c.window.firstResponder as? NSTextView, "the answer field must be editing")
        editor.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    private func answers() -> [String?] { replies.map { try? $0.get().text } }

    private func showsToast(_ text: String, in c: WindowController) -> Bool {
        guard let content = c.window.contentView else { return false }
        func all(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + all($0) } }
        return all(content).contains { ($0 as? NSTextField)?.stringValue.contains(text) == true }
    }

    func test_connectStaysOnConnectWhileTheLoginRuns_thenMountsTheTerminalOnceConnected() throws {
        let (c, login) = try loggingIn()
        let view = try XCTUnwrap(c.connectViewForTesting, "the login runs behind the Connect screen")

        XCTAssertEqual(login.startCount, 1)
        XCTAssertEqual(login.lastConfig?.environment["SSH_ASKPASS_REQUIRE"], "force")
        XCTAssertEqual(view.statusForTesting, "Connecting…")
        XCTAssertNotNil(view.cancelButtonForTesting)
        XCTAssertNil(c.activeTabIDForTesting)

        fake.connect()

        XCTAssertNil(c.connectViewForTesting)
        XCTAssertEqual(c.activeConnectionForTesting?.state, .connected)
    }

    func test_aPasswordIsTypedHidden_andReturnAnswersSSH_withFocusInTheField() throws {
        let (c, login) = try loggingIn()
        try ask("devbox's password: ", login: login, in: c)
        let view = try XCTUnwrap(c.connectViewForTesting)

        XCTAssertEqual(view.promptForTesting, "Enter your password")
        let field = try XCTUnwrap(view.answerFieldForTesting)
        XCTAssertTrue(field.field.cell is NSSecureTextFieldCell)
        XCTAssertTrue((c.window.firstResponder as? NSText)?.delegate === field.field, "the field takes focus")
        try type("hunter2", in: c)
        try send(keyCode: 36, "\r", in: c)

        XCTAssertEqual(answers(), ["hunter2"])
        XCTAssertNil(view.answerFieldForTesting)
        XCTAssertEqual(view.statusForTesting, "Connecting…")
    }

    func test_aRepeatedPrompt_saysTheLastAnswerDidNotWork() throws {
        let (c, login) = try loggingIn()
        try ask("devbox's password: ", login: login, in: c)
        try type("wrong", in: c)
        try send(keyCode: 36, "\r", in: c)
        let view = try XCTUnwrap(c.connectViewForTesting)
        XCTAssertNil(view.retryForTesting)

        try ask("devbox's password: ", login: login, in: c)

        XCTAssertEqual(view.retryForTesting, "That didn't work. Try again.")
        XCTAssertEqual(view.answerFieldForTesting?.text, "", "the last answer never stays in the field")
    }

    func test_aNewHostKey_showsItsFingerprint_andTrustAnswersYes() throws {
        let (c, login) = try loggingIn()
        try ask(
            "ED25519 key fingerprint is: SHA256:abc123\nAre you sure (yes/no/[fingerprint])? ", login: login, in: c)
        let view = try XCTUnwrap(c.connectViewForTesting)

        XCTAssertEqual(view.promptForTesting, "New ED25519 host key")
        XCTAssertEqual(view.fingerprintForTesting, "SHA256:\nabc123")
        XCTAssertNil(view.answerFieldForTesting, "a host key has no free-text answer")
        try XCTUnwrap(view.trustButtonForTesting).performClick(nil)

        XCTAssertEqual(answers(), ["yes"])
    }

    func test_returnOnAHostKey_trustsIt() throws {
        let (c, login) = try loggingIn()
        try ask("Are you sure you want to continue connecting (yes/no/[fingerprint])? ", login: login, in: c)

        try send(keyCode: 36, "\r", in: c)

        XCTAssertEqual(answers(), ["yes"])
    }

    func test_escapeInTheAnswerField_endsTheLogin_andReturnsToConnect() throws {
        let (c, login) = try loggingIn()
        try ask("devbox's password: ", login: login, in: c)

        try pressEscape(in: c)

        XCTAssertNil(c.connectionForTesting(of: host), "cancel ends the login's workspace and its ssh")
        guard case .failure(let error)? = replies.first else { return XCTFail("\(replies)") }
        XCTAssertEqual(error.code, .failed)
        let view = try XCTUnwrap(c.connectViewForTesting)
        XCTAssertNil(view.cancelButtonForTesting)
        XCTAssertNotEqual(view.statusForTesting, "Connecting…")
        XCTAssertFalse(showsToast("Couldn't connect", in: c), "a cancel is not a failure")
    }

    func test_escapeOnConnectWhileConnecting_endsTheLogin() throws {
        let (c, _) = try loggingIn()

        try pressEscape(in: c)

        XCTAssertNil(c.connectionForTesting(of: host))
    }

    func test_whileConnecting_noPathOpensTheHiddenWorkspace() throws {
        let (c, _) = try loggingIn()
        let tab = try XCTUnwrap(c.tabIDsForTesting(of: host).first)

        c.selectTab(tab)
        XCTAssertNotNil(c.connectViewForTesting, "reveal(TabID) stays on Connect")
        c.activate(host)
        XCTAssertNotNil(c.connectViewForTesting, "the host row stays on Connect")
        let ids = c.workspaceIDsForTesting
        for id in ids { c.activateWorkspace(id) }
        XCTAssertNotNil(c.connectViewForTesting, "activating the workspace by id stays on Connect")
        c.handle(.newTab)
        XCTAssertEqual(c.tabIDsForTesting(of: host).count, 1, "⌘T on Connect never starts a second login")
    }

    func test_closingConnectWhileTheOnlyWorkspaceLogsIn_neverLandsInIt() throws {
        let (c, _) = try loggingIn()
        for id in c.workspaceIDsForTesting where c.host(of: id) == nil { c.removeWorkspace(id) }

        c.handle(.closePane)

        XCTAssertNotNil(c.connectViewForTesting)
        XCTAssertNotNil(c.connectionForTesting(of: host))
    }

    func test_aLoginThatConnects_closesACardOpenOverConnect() throws {
        let (c, _) = try loggingIn()
        c.handle(.searchSelection)
        XCTAssertTrue(shows(AddSSHHostOverlay.self, in: c), "Edit Host opens over Connect while it logs in")

        fake.connect()

        XCTAssertNil(c.connectViewForTesting)
        XCTAssertFalse(shows(AddSSHHostOverlay.self, in: c), "a card for Connect must not stay over the new terminal")
    }

    private func shows<View: NSView>(_ type: View.Type, in c: WindowController) -> Bool {
        guard let content = c.window.contentView else { return false }
        func all(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + all($0) } }
        return all(content).contains { $0 is View && !$0.isHidden }
    }

    func test_closingTheOnlyLocalWorkspaceWhileALoginRuns_landsOnItsConnect() throws {
        let (c, _) = try loggingIn()
        let local = try XCTUnwrap(c.workspaceIDsForTesting.first { c.host(of: $0) == nil })
        c.activateWorkspace(local)
        XCTAssertNil(c.connectViewForTesting)

        c.closeTabForTesting(index: 0)

        XCTAssertNotNil(c.connectViewForTesting, "the window lands on the login's Connect, not a blank canvas")
        fake.connect()
        XCTAssertEqual(c.activeConnectionForTesting?.state, .connected, "and its connect still mounts the terminal")
    }

    func test_aLoginThatConnectsWhileAnotherWorkspaceShows_leavesThatWorkspaceUp() throws {
        let (c, _) = try loggingIn()
        let local = try XCTUnwrap(c.workspaceIDsForTesting.first { c.host(of: $0) == nil })
        c.activateWorkspace(local)

        fake.connect()

        XCTAssertEqual(c.activeWorkspaceIDForTesting, local)
    }

    func test_sshsLatestLineShowsAsTheDetail_withoutTheLoginBannerOrWhatTheScreenAlreadySays() throws {
        let (c, login) = try loggingIn()
        let expected = "Confirm user presence for key ED25519 SHA256:x"
        login.rows = [
            "Last login: Wed Nov 25 01:41:47 on ttys015", "Confirm user presence for key ED25519 SHA256:x\r",
            "", "Permission denied, please try again.",
            "Warning: Permanently added 'devbox' (ED25519) to the list of known hosts.",
        ]

        let deadline = Date().addingTimeInterval(2)
        while c.connectViewForTesting?.detailForTesting != expected, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }

        XCTAssertEqual(c.connectViewForTesting?.detailForTesting, expected, "the screen follows the login's terminal")
    }

    func test_aRepeatedPrompt_takesSSHsOwnDenial_asTheRetryNote() throws {
        let (c, login) = try loggingIn()
        try ask("devbox's password: ", login: login, in: c)
        try type("wrong", in: c)
        try send(keyCode: 36, "\r", in: c)
        login.rows = ["Permission denied, please try again."]
        let connection = try XCTUnwrap(c.connectionForTesting(of: host))
        XCTAssertEqual(connection.loginOutput(limit: HostConnectView.outputLinesRead), login.rows)

        try ask("devbox's password: ", login: login, in: c)

        let view = try XCTUnwrap(c.connectViewForTesting)
        XCTAssertEqual(view.retryForTesting, "Permission denied, please try again.")
        XCTAssertNil(view.detailForTesting, "said once, as the retry note")
    }

    func test_aLongPrompt_wrapsIntoBalancedLines_andIsNeverTruncated() throws {
        let (c, login) = try loggingIn()
        let prompt =
            "(me@devbox) Enter the six digit code from the authenticator app on your phone to finish signing in"

        try ask(prompt, login: login, in: c)

        let message = try XCTUnwrap(c.connectViewForTesting).messageLabelForTesting
        XCTAssertEqual(message.stringValue, String(prompt.dropFirst("(me@devbox) ".count)))
        XCTAssertEqual(message.lineBreakMode, .byWordWrapping)
        XCTAssertGreaterThan(message.lineCountForTesting, 1)
        XCTAssertLessThan(message.frame.width, 360, "balanced lines sit narrower than the message width")
    }

    func test_aFailedLogin_returnsConnectToReady_withTheFailureToast() throws {
        let (c, _) = try loggingIn()

        fake.unwatchable?()
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 2)

        let view = try XCTUnwrap(c.connectViewForTesting)
        XCTAssertNil(view.cancelButtonForTesting)
        XCTAssertNil(c.connectionForTesting(of: host))
        XCTAssertTrue(showsToast("Couldn't connect", in: c))
    }

    func test_withoutZen_connectMountsTheTerminalAtOnce_andSSHPromptsThere() throws {
        SSHConnection.askpassProgramOverrideForTesting = .some(nil)
        let (c, login) = try loggingIn()

        XCTAssertNil(c.connectViewForTesting)
        XCTAssertNil(login.lastConfig?.environment["SSH_ASKPASS"])
    }
}
