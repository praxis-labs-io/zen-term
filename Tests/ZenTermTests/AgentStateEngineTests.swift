import TerminalKit
import XCTest

@testable import ZenTerm

/// Fixture titles from the ZEN-468 probe, measured 2026-09-17 against Claude Code and Codex.
enum AgentTitleFixtures {
    static let codexWorking = ["⠋ Working", "⠙ Working", "⠹ Working", "⠸ Working", "⠼ Working"]
    static let codexBlockedOn = "[ ! ] Action Required | zen-term"
    static let codexBlockedOff = "[ . ] Action Required | zen-term"
    static let codexIdle = "zen-term"
    static let claudeWorking = "◐ Multiple choice question tool"
    static let claudeWorkingAlternate = "◑ Bash tool"
    static let claudeIdle = "✳ zen-term"
}

final class AgentStateEngineTests: XCTestCase {
    private func codexState(_ title: String) -> AgentSignalState? {
        AgentStateEngine.evaluate(AgentRules.rules(for: "codex"), title: title, progress: "4;0").state
    }

    func test_everyCodexSpinnerFrame_readsWorking() {
        for title in AgentTitleFixtures.codexWorking {
            XCTAssertEqual(codexState(title), .working, "\(title) is a spinner frame")
        }
    }

    func test_bothHalvesOfCodexBlink_readBlocked() {
        let cases = [AgentTitleFixtures.codexBlockedOn, AgentTitleFixtures.codexBlockedOff]
        for title in cases {
            XCTAssertEqual(codexState(title), .blocked, "\(title) is the same prompt, mid-blink")
        }
    }

    func test_codexBareCWD_readsIdle() {
        XCTAssertEqual(codexState(AgentTitleFixtures.codexIdle), .idle)
    }

    func test_blocked_outranksWorking_whenBothMatch() {
        XCTAssertEqual(codexState("⠹ [ ! ] Action Required | zen-term"), .blocked)
    }

    func test_claudeTitle_neverMovesState() {
        let rules = AgentRules.rules(for: "claude")
        let cases = [
            AgentTitleFixtures.claudeWorking, AgentTitleFixtures.claudeIdle,
            AgentTitleFixtures.codexBlockedOn,
        ]
        for title in cases {
            let outcome = AgentStateEngine.evaluate(rules, title: title, progress: "4;3")
            XCTAssertEqual(outcome.state, .working, "\(title) must not outvote progress")
        }
    }

    func test_claudeProgress_carriesBothEnds() {
        let rules = AgentRules.rules(for: "claude")
        let cases: [(progress: TerminalProgress?, expected: AgentSignalState)] = [
            (TerminalProgress(state: .indeterminate), .working),
            (nil, .idle),
        ]
        for item in cases {
            let outcome = AgentStateEngine.evaluate(
                rules, title: "", progress: AgentRules.progressRegion(item.progress))
            XCTAssertEqual(outcome.state, item.expected)
        }
    }

    func test_aDeterminateReport_isAProgressBar_notAnAgentTurn() {
        let region = AgentRules.progressRegion(TerminalProgress(state: .running, fraction: 0.4))
        let outcome = AgentStateEngine.evaluate(AgentRules.rules(for: "claude"), title: "", progress: region)

        XCTAssertEqual(outcome, .fallback)
        XCTAssertEqual(outcome.state, .idle)
    }

    func test_anAgentWeShipNoRulesFor_isNeverBlockedByAnotherAgentsTitle() {
        let outcome = AgentStateEngine.evaluate(
            AgentRules.rules(for: "some-new-agent"), title: AgentTitleFixtures.codexBlockedOn,
            progress: AgentRules.clearedProgress)

        XCTAssertEqual(outcome.state, .idle, "Codex's prompt means nothing on an agent that is not Codex")
    }

    func test_anAgentWeShipNoRulesFor_stillGetsProgress() {
        let rules = AgentRules.rules(for: "some-new-agent")
        let cases: [(progress: String, expected: AgentSignalState)] = [("4;3", .working), ("4;0", .idle)]

        for item in cases {
            XCTAssertEqual(
                AgentStateEngine.evaluate(rules, title: "", progress: item.progress).state, item.expected,
                "any program that reports OSC 9;4 gets this for free")
        }
    }

    func test_anUnrecognizedCodexTitle_fallsBack_ratherThanMatchingIdle() {
        let outcome = AgentStateEngine.evaluate(
            AgentRules.rules(for: "codex"), title: AgentTitleFixtures.codexIdle, progress: "4;0")

        XCTAssertEqual(outcome, .fallback, "idle is the absence of evidence here, not a rule")
    }

    func test_highestPriorityWins_whateverTheRuleOrder() {
        let rules = [
            AgentStateRule(id: "low", state: .idle, priority: 1, region: .oscTitle, match: .contains("x")),
            AgentStateRule(id: "high", state: .blocked, priority: 9, region: .oscTitle, match: .contains("x")),
            AgentStateRule(id: "mid", state: .working, priority: 5, region: .oscTitle, match: .contains("x")),
        ]

        XCTAssertEqual(AgentStateEngine.evaluate(rules, title: "x", progress: ""), .matched(.blocked, ruleID: "high"))
    }

    func test_aTie_keepsTheFirstRule() {
        let rules = [
            AgentStateRule(id: "first", state: .working, priority: 5, region: .oscTitle, match: .contains("x")),
            AgentStateRule(id: "second", state: .blocked, priority: 5, region: .oscTitle, match: .contains("x")),
        ]

        XCTAssertEqual(AgentStateEngine.evaluate(rules, title: "x", progress: ""), .matched(.working, ruleID: "first"))
    }

    func test_skipStateUpdate_provesNothing() {
        let rules = [
            AgentStateRule(
                id: "viewer", state: .idle, priority: 9, region: .oscTitle, skipStateUpdate: true,
                match: .contains("transcript")),
            AgentStateRule(id: "working", state: .working, priority: 1, region: .oscTitle, match: .contains("x")),
        ]

        let outcome = AgentStateEngine.evaluate(rules, title: "x transcript", progress: "")

        XCTAssertEqual(outcome, .skip(ruleID: "viewer"))
        XCTAssertNil(outcome.state, "a skip holds whatever was published, it does not lower it")
    }

    func test_theRegionPicksWhichSignalARuleReads() {
        let rules = [
            AgentStateRule(id: "title", state: .blocked, priority: 1, region: .oscTitle, match: .contains("needle")),
            AgentStateRule(id: "progress", state: .working, priority: 1, region: .oscProgress, match: .contains("4;3")),
        ]

        XCTAssertEqual(
            AgentStateEngine.evaluate(rules, title: "needle", progress: ""), .matched(.blocked, ruleID: "title"))
        XCTAssertEqual(
            AgentStateEngine.evaluate(rules, title: "", progress: "4;3"), .matched(.working, ruleID: "progress"))
    }
}

final class RuleMatcherTests: XCTestCase {
    func test_matchers() {
        let cases: [(name: String, matcher: RuleMatcher, text: String, expected: Bool)] = [
            ("contains hits", .contains("Action Required"), "[ ! ] Action Required | zen", true),
            ("contains ignores case", .contains("action required"), "[ ! ] Action Required", true),
            ("contains misses", .contains("Action Required"), "zen-term", false),
            ("regex hits", .regex("^⠋"), "⠋ Working", true),
            ("regex misses", .regex("^⠋"), " ⠋ Working", false),
            ("lineRegex finds a later line", .lineRegex("^❯"), "header\n❯ yes", true),
            ("lineRegex is anchored per line", .lineRegex("^❯"), "header ❯ yes", false),
            ("all needs every branch", .all([.contains("a"), .contains("b")]), "a b", true),
            ("all fails on one miss", .all([.contains("a"), .contains("z")]), "a b", false),
            ("any needs one branch", .any([.contains("z"), .contains("b")]), "a b", true),
            ("any fails on all misses", .any([.contains("y"), .contains("z")]), "a b", false),
            ("not inverts", .not([.contains("z")]), "a b", true),
            ("not fails when a branch hits", .not([.contains("a")]), "a b", false),
            (
                "nesting composes", .all([.contains("a"), .any([.contains("z"), .not([.contains("q")])])]), "a b",
                true
            ),
        ]

        for item in cases {
            XCTAssertEqual(item.matcher.matches(item.text), item.expected, item.name)
        }
    }

    func test_anInvalidPattern_matchesNothing_ratherThanCrashing() {
        XCTAssertFalse(RuleMatcher.regex("[unterminated").matches("anything"))
    }
}

final class AgentRulesKeyTests: XCTestCase {
    func test_aKeyIsFound_whateverTheSourceNamedTheAgent() {
        let cases: [(name: String?, expected: String?)] = [
            ("claude", "claude"),
            ("Claude Code", "claude"),
            ("codex", "codex"),
            ("Codex", "codex"),
            ("some-new-agent", nil),
            ("", nil),
            (nil, nil),
        ]

        for item in cases {
            XCTAssertEqual(AgentRules.key(for: item.name), item.expected, "\(item.name ?? "nil")")
        }
    }

    func test_claudesMessage_isTheToolName_withoutTheSpinner() {
        XCTAssertEqual(
            AgentRules.message(fromTitle: AgentTitleFixtures.claudeWorking, agentName: "claude"),
            "Multiple choice question tool")
        XCTAssertEqual(
            AgentRules.message(fromTitle: AgentTitleFixtures.claudeWorkingAlternate, agentName: "claude"), "Bash tool")
        XCTAssertEqual(AgentRules.message(fromTitle: AgentTitleFixtures.claudeIdle, agentName: "claude"), "zen-term")
    }

    func test_onlyClaudeTakesItsMessageFromTheTitle() {
        XCTAssertNil(AgentRules.message(fromTitle: AgentTitleFixtures.codexIdle, agentName: "codex"))
    }
}
