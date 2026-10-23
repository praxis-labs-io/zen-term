import XCTest

@testable import ZenTerm

final class AgentRosterTests: XCTestCase {
    private let id = SurfaceIDs.mint()

    func test_aRealName_replacesAMissingOne_atTheSameRank() {
        let roster = AgentRoster()
        roster.identify(id, name: nil, source: .signal)

        roster.identify(id, name: "Claude Code", source: .signal)

        XCTAssertEqual(roster.agents[id]?.name, "Claude Code")
    }

    func test_aMissingName_neverReplacesARealOne() {
        let roster = AgentRoster()
        roster.identify(id, name: "claude", source: .signal)

        roster.identify(id, name: nil, source: .launch)

        XCTAssertEqual(roster.agents[id]?.name, "claude")
    }

    func test_aRealName_isKept_againstAnotherAtTheSameRank() {
        let roster = AgentRoster()
        roster.identify(id, name: "Claude Code", source: .signal)

        roster.identify(id, name: "Codex", source: .signal)

        XCTAssertEqual(roster.agents[id]?.name, "Claude Code")
    }

    func test_aRealName_isKept_againstALowerRank() {
        let roster = AgentRoster()
        roster.identify(id, name: "claude", source: .launch)

        roster.identify(id, name: "Claude Code", source: .signal)

        XCTAssertEqual(roster.agents[id]?.name, "claude")
    }

    func test_aHigherRank_renamesARealName() {
        let roster = AgentRoster()
        roster.identify(id, name: "Claude Code", source: .signal)

        roster.identify(id, name: "claude", source: .launch)

        XCTAssertEqual(roster.agents[id]?.name, "claude")
    }

    func test_aNotificationTitle_namesAKnownAgentOrAListedOne() {
        XCTAssertEqual(AgentRoster.agentName(notifying: "Claude Code", listed: []), "claude")
        XCTAssertEqual(AgentRoster.agentName(notifying: "codex", listed: []), "codex")
        XCTAssertEqual(AgentRoster.agentName(notifying: "Gemini is waiting", listed: ["pi", "gemini"]), "gemini")
    }

    func test_aLaunch_namesAKnownOrListedProgram_byItsName() {
        XCTAssertEqual(AgentRoster.agentName(launching: "/opt/bin/claude --resume", listed: []), "claude")
        XCTAssertEqual(AgentRoster.agentName(launching: "gemini --yolo", listed: ["pi", "gemini"]), "gemini")
        XCTAssertEqual(AgentRoster.agentName(launching: "Gemini", listed: ["gemini"]), "Gemini")
        XCTAssertNil(AgentRoster.agentName(launching: "vim", listed: ["pi", "gemini"]))
    }

    func test_aNotificationTitle_namingNoAgent_isNoAgent() {
        for title in ["", "build", "btop", "make: done", "pipeline finished"] {
            XCTAssertNil(AgentRoster.agentName(notifying: title, listed: ["pi"]), "\(title) names no agent")
        }
    }

    func test_aConfiguredProgramWithPunctuation_matchesAsAWholeToken() {
        XCTAssertEqual(AgentRoster.agentName(notifying: "gemini-cli", listed: ["gemini-cli"]), "gemini-cli")
        XCTAssertEqual(AgentRoster.agentName(notifying: "Done: gemini-cli.", listed: ["gemini-cli"]), "gemini-cli")
        XCTAssertEqual(AgentRoster.agentName(notifying: "aider.chat", listed: ["aider.chat"]), "aider.chat")
        XCTAssertNil(AgentRoster.agentName(notifying: "gemini", listed: ["gemini-cli"]))
    }
}
