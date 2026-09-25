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

    func test_aNotificationTitle_namesAKnownAgentOrTheConfiguredOne() {
        XCTAssertEqual(AgentRoster.agentName(notifying: "Claude Code", ai: nil), "claude")
        XCTAssertEqual(AgentRoster.agentName(notifying: "codex", ai: nil), "codex")
        XCTAssertEqual(AgentRoster.agentName(notifying: "pi", ai: "pi --model sonnet"), "pi")
    }

    func test_aNotificationTitle_namingNoAgent_isNoAgent() {
        for title in ["", "build", "btop", "make: done", "pipeline finished"] {
            XCTAssertNil(AgentRoster.agentName(notifying: title, ai: "pi"), "\(title) names no agent")
        }
    }
}
