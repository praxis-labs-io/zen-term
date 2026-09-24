import AppKit
import TabKit
import TerminalKit
import XCTest

@testable import ZenTerm

/// The title only reaches the chrome through a real delegate, so these drive the surface, never the handler.
@MainActor
final class AgentTitleRoutingTests: WindowTestCase {
    private var originalOverride: (() -> TerminalSurface)?
    private var controller: WindowController?
    private var spawned: [RecordingSurface] = []
    private let originalPresence = WindowController.isPresent

    override func setUpWithError() throws {
        try super.setUpWithError()
        WindowController.isPresent = { _ in true }
        originalOverride = TerminalSurfaceFactory.makeOverride
        Motion.isReduceMotionEnabled = { true }
        TerminalSurfaceFactory.makeOverride = { [weak self] in
            let surface = RecordingSurface()
            self?.spawned.append(surface)
            return surface
        }
    }

    override func tearDownWithError() throws {
        controller?.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        controller = nil
        spawned = []
        TerminalSurfaceFactory.makeOverride = originalOverride
        WindowController.isPresent = originalPresence
        try super.tearDownWithError()
    }

    private func makeWindow() -> WindowController {
        let c = WindowController(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), initialCWD: nil)
        c.mountAndStart()
        controller = c
        return c
    }

    private func drainMainQueue() {
        let expectation = expectation(description: "main queue")
        DispatchQueue.main.async { expectation.fulfill() }
        wait(for: [expectation], timeout: 2)
    }

    private func push(_ title: String, from surface: RecordingSurface) {
        surface.delegate?.surface(surface, titleDidChange: title)
        drainMainQueue()
    }

    func test_aDrawersTitle_reachesTheAgent() throws {
        let c = makeWindow()
        let before = spawned.count
        c.handle(.toggleRightDrawer)
        let drawer = try XCTUnwrap(spawned.dropFirst(before).first, "opening the drawer spawns its surface")
        drainMainQueue()
        let id = try XCTUnwrap(c.drawerSurfaceIDsForTesting(tabIndex: 0).right)
        c.identifyAgentForTesting(id, name: "codex")

        push(AgentTitleFixtures.codexWorking[0], from: drawer)

        XCTAssertEqual(
            c.agentStateForTesting(id), .working,
            "every workspace recipe puts its agent in a drawer, so this is the path that matters")
    }

    func test_anUnfocusedSplitsTitle_reachesTheAgent() throws {
        let c = makeWindow()
        c.handle(.splitVertical)
        drainMainQueue()
        let ids = c.surfaceIDsForTesting(tabIndex: 0)
        XCTAssertEqual(ids.count, 2, "got \(ids)")
        let unfocused = try XCTUnwrap(ids.first { $0 != c.focusedSurfaceIDForTesting })
        let surface = try XCTUnwrap(c.terminalSurfaceForTesting(unfocused) as? RecordingSurface)
        c.identifyAgentForTesting(unfocused, name: "codex")

        push(AgentTitleFixtures.codexWorking[0], from: surface)

        XCTAssertEqual(
            c.agentStateForTesting(unfocused), .working,
            "an agent working in a background split still reports")
    }

    func test_aCodexPromptInADrawer_readsWaiting() throws {
        let c = makeWindow()
        let before = spawned.count
        c.handle(.toggleRightDrawer)
        let drawer = try XCTUnwrap(spawned.dropFirst(before).first)
        drainMainQueue()
        let id = try XCTUnwrap(c.drawerSurfaceIDsForTesting(tabIndex: 0).right)
        c.identifyAgentForTesting(id, name: "codex")

        push(AgentTitleFixtures.codexBlockedOn, from: drawer)

        XCTAssertEqual(c.agentStateForTesting(id), .waiting)
    }

    func test_aClaudeTurnInADrawer_showsItsToolName() throws {
        let c = makeWindow()
        let before = spawned.count
        c.handle(.toggleRightDrawer)
        let drawer = try XCTUnwrap(spawned.dropFirst(before).first)
        drainMainQueue()
        let id = try XCTUnwrap(c.drawerSurfaceIDsForTesting(tabIndex: 0).right)
        c.identifyAgentForTesting(id, name: "claude")
        drawer.delegate?.surface(drawer, progressDidChange: TerminalProgress(state: .indeterminate))
        drainMainQueue()

        push(AgentTitleFixtures.claudeWorking, from: drawer)

        XCTAssertEqual(c.agentMessageForTesting(id), "Multiple choice question tool")
    }

    func test_aCodexNobodyLaunched_joinsOnItsOwnTitle() throws {
        let c = makeWindow()
        let surface = try XCTUnwrap(spawned.first)
        let id = try XCTUnwrap(c.surfaceIDsForTesting(tabIndex: 0).first)

        push(AgentTitleFixtures.codexWorking[0], from: surface)

        XCTAssertEqual(
            c.agentRowForTesting(id)?.detail.contains("codex"), true,
            "codex emits no progress and its notification is unreliable, so the title is its only way in")
        XCTAssertEqual(c.agentStateForTesting(id), .working)
    }

    func test_aHandLaunchedCodex_thenAsking_readsWaiting() throws {
        let c = makeWindow()
        let surface = try XCTUnwrap(spawned.first)
        let id = try XCTUnwrap(c.surfaceIDsForTesting(tabIndex: 0).first)
        push(AgentTitleFixtures.codexWorking[0], from: surface)

        push(AgentTitleFixtures.codexBlockedOn, from: surface)

        XCTAssertEqual(c.agentStateForTesting(id), .waiting)
    }

    func test_answeringABlockedCodex_doesNotLeaveItWorking() throws {
        let c = makeWindow()
        let surface = try XCTUnwrap(spawned.first)
        let id = try XCTUnwrap(c.surfaceIDsForTesting(tabIndex: 0).first)
        push(AgentTitleFixtures.codexWorking[0], from: surface)
        push(AgentTitleFixtures.codexBlockedOn, from: surface)

        c.answerAgentForTesting(id)

        XCTAssertNotEqual(
            c.agentRowForTesting(id)?.state, .working,
            "an agent that stopped to ask is not mid-turn, so answering must not fall back to working")
    }

    func test_aTitleFromASurfaceThatIsNoAgent_changesNothing() throws {
        let c = makeWindow()
        let surface = try XCTUnwrap(spawned.first)

        push(AgentTitleFixtures.codexBlockedOn, from: surface)

        XCTAssertNil(c.attentionStateForTesting(tabIndex: 0), "a shell is not an agent")
    }
}
