import AppKit
import TabKit
import TerminalKit
import XCTest

@testable import ZenTerm

/// Codex posts the same OSC 777 at the end of a turn as it does on an approval prompt.
@MainActor
final class CodexNotificationTests: WindowTestCase {
    private var originalOverride: (() -> TerminalSurface)?
    private var originalConfig: GeneralConfig!
    private var controller: WindowController?
    private var spawned: [RecordingSurface] = []
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
        var config = GeneralConfig.builtIn
        config.attentionToast = .sticky
        config.completionToast = .sticky
        GeneralConfig.setCurrentForTesting(config)
    }

    override func tearDownWithError() throws {
        controller?.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        controller = nil
        spawned = []
        TerminalSurfaceFactory.makeOverride = originalOverride
        GeneralConfig.setCurrentForTesting(originalConfig)
        WindowController.isPresent = originalPresence
        try super.tearDownWithError()
    }

    private func drainMainQueue() {
        let expectation = expectation(description: "main queue")
        DispatchQueue.main.async { expectation.fulfill() }
        wait(for: [expectation], timeout: 2)
    }

    /// An agent in a closed right drawer, so its notification is never "seen".
    private func agentInADrawer(_ name: String = "codex") throws -> (
        WindowController, RecordingSurface, SurfaceID
    ) {
        let c = WindowController(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), initialCWD: nil)
        c.mountAndStart()
        controller = c
        let before = spawned.count
        c.handle(.toggleRightDrawer)
        let surface = try XCTUnwrap(spawned.dropFirst(before).first)
        c.handle(.toggleRightDrawer)
        drainMainQueue()
        let id = try XCTUnwrap(c.drawerSurfaceIDsForTesting(tabIndex: 0).right)
        c.identifyAgentForTesting(id, name: name)
        return (c, surface, id)
    }

    private func push(_ title: String, from surface: RecordingSurface) {
        surface.delegate?.surface(surface, titleDidChange: title)
        drainMainQueue()
    }

    private func notify(_ surface: RecordingSurface, _ body: String) {
        surface.delegate?.surface(surface, didPostNotification: TerminalNotification(title: "", body: body))
        drainMainQueue()
    }

    func test_aPromptTitle_makesTheNotificationAsk() throws {
        let (c, surface, id) = try agentInADrawer()
        push(AgentTitleFixtures.codexBlockedOn, from: surface)

        notify(surface, "Approve running `rm -rf build`?")

        XCTAssertEqual(c.agentStateForTesting(id), .waiting)
    }

    func test_noPromptTitle_makesTheNotificationACompletion() throws {
        let (c, surface, id) = try agentInADrawer()
        push(AgentTitleFixtures.codexIdle, from: surface)

        notify(surface, "Renamed the helper and updated its two callers.")

        XCTAssertEqual(
            c.agentStateForTesting(id), .completed,
            "every finished Codex turn used to read as needing you")
    }

    func test_aFinishedTurn_keepsItsAnswerAsTheRowsLine() throws {
        let (c, surface, id) = try agentInADrawer()
        push(AgentTitleFixtures.codexIdle, from: surface)

        notify(surface, "Renamed the helper.")

        XCTAssertEqual(c.agentMessageForTesting(id), "Renamed the helper.")
    }

    func test_anAgentThatIsNotCodex_isTakenAtItsWord() throws {
        let (c, surface, id) = try agentInADrawer("claude")
        push(AgentTitleFixtures.claudeIdle, from: surface)

        notify(surface, "Claude is waiting for your input")

        XCTAssertEqual(
            c.agentStateForTesting(id), .waiting,
            "only Codex is ambiguous here, and only Codex gets second-guessed")
    }

    func test_aBlockedCodexTurn_stillRaisesACard() throws {
        let (c, surface, _) = try agentInADrawer()
        push(AgentTitleFixtures.codexBlockedOn, from: surface)

        notify(surface, "Approve?")

        XCTAssertEqual(c.waitingToastForTesting(tabIndex: 0)?.variantForTesting, .info)
    }

    func test_aFinishedCodexTurn_raisesACompletionCard() throws {
        let (c, surface, _) = try agentInADrawer()
        push(AgentTitleFixtures.codexIdle, from: surface)

        notify(surface, "Done.")

        XCTAssertEqual(c.waitingToastForTesting(tabIndex: 0)?.variantForTesting, .positive)
    }
}
