import AppKit
import ControlProtocol
import TerminalKit
import XCTest

@testable import ZenTerm

final class PaneWaitLiveSurfaceTests: WindowTestCase {
    private var originalOverride: (() -> TerminalSurface)?
    private var originalConfig: GeneralConfig!
    private var controller: WindowController?
    private var surfaces: [GhosttySurface] = []
    private let waits = PaneWaits()
    private let originalPresence = WindowController.isPresent

    override func setUpWithError() throws {
        try super.setUpWithError()
        WindowController.isPresent = { _ in true }
        originalOverride = TerminalSurfaceFactory.makeOverride
        originalConfig = GeneralConfig.current
        var config = GeneralConfig.builtIn
        config.shell = "/bin/zsh"
        GeneralConfig.setCurrentForTesting(config)
        TerminalSurfaceFactory.makeOverride = { [weak self] in
            let surface = GhosttySurface()
            self?.surfaces.append(surface)
            return surface
        }
    }

    override func tearDownWithError() throws {
        waits.pending.forEach { $0.cancel() }
        if let controller {
            controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
            AttentionCenter.shared.forget(windowID: controller.windowID)
        }
        controller = nil
        surfaces.forEach { $0.terminate() }
        surfaces = []
        TerminalSurfaceFactory.makeOverride = originalOverride
        GeneralConfig.setCurrentForTesting(originalConfig)
        WindowController.isPresent = originalPresence
        try super.tearDownWithError()
    }

    private func shellPane() throws -> (surface: GhosttySurface, token: Int) {
        let c = WindowController(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            initialCWD: FileManager.default.temporaryDirectory)
        c.paneWaits = waits
        c.mountAndStart()
        c.window.orderFront(nil)
        c.window.contentView?.layoutSubtreeIfNeeded()
        controller = c
        let surface = try XCTUnwrap(surfaces.first)
        try XCTSkipIf(!surface.isStarted, "ghostty_surface_new failed")
        let token = try XCTUnwrap(c.listing().workspaces.first?.tabs.first?.panes.first?.token)
        waitUntil(atPrompt(surface), "the shell's first prompt", timeout: 15)
        return (surface, token)
    }

    private func atPrompt(_ surface: GhosttySurface) -> Bool {
        guard let group = surface.foregroundProcessGroupID else { return false }
        return ForegroundGroup.isShell(group) && !(surface.activeScreenText ?? "").allSatisfy(\.isWhitespace)
    }

    private final class Answer {
        var reply: ControlReply?
    }

    private func wait(on pane: Int) -> Answer {
        let answer = Answer()
        let responder = ControlResponder(
            windows: { [unowned self] in controller.map { [$0] } ?? [] }, keyWindow: { [unowned self] in controller },
            paneWaits: waits)
        responder.respond(
            to: ControlRequest(
                id: 1, cmd: .paneWait, args: ControlArgs(pane: .token(pane), timeout: 30))
        ) { answer.reply = $0 }
        return answer
    }

    private func run(_ command: String, in surface: GhosttySurface) {
        surface.paste(command)
        surface.submit()
    }

    private func result(_ answer: Answer) throws -> WaitResult {
        waitUntil(answer.reply != nil, "the wait to answer", timeout: 10)
        let reply = try XCTUnwrap(answer.reply)
        return try XCTUnwrap(try reply.get() as? WaitResult, "\(reply)")
    }

    func test_aCommandThatExitsAnswersExited_withTheShellsExitCode() throws {
        let (surface, token) = try shellPane()
        let answer = wait(on: token)

        run("echo zen-failing; sleep 0.3; (exit 3)", in: surface)

        let got = try result(answer)
        XCTAssertEqual(got.reason, .exited)
        XCTAssertEqual(got.exitCode, 3)
        XCTAssertEqual(got.text?.contains("zen-failing"), true, got.text ?? "")
    }

    func test_thePanesShellReadsAsTheShell_andAJobItRunsDoesNot() throws {
        let (surface, _) = try shellPane()
        run("sleep 5", in: surface)
        waitUntil(
            surface.foregroundProcessGroupID.flatMap(ProcessArguments.programName(of:)) == "sleep",
            "sleep in the foreground", timeout: 10)
        let job = try XCTUnwrap(surface.foregroundProcessGroupID)
        XCTAssertFalse(ForegroundGroup.isShell(job))
    }
}
