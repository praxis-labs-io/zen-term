import TerminalKit
import XCTest

@testable import ZenTerm

enum AgentTitleFixtures {
    static let codexWorking = [
        "⠋ Create test.txt | drucial", "⠙ Create test.txt | drucial", "⠹ Create test.txt | drucial",
        "⠸ Create test.txt | drucial", "⠼ Create test.txt | drucial", "⠴ Create test.txt | drucial",
        "⠦ Create test.txt | drucial", "⠧ Create test.txt | drucial", "⠇ Create test.txt | drucial",
        "⠏ Create test.txt | drucial",
    ]
    static let codexBlockedOn = "[ ! ] Action Required | Create test.txt | drucial"
    static let codexBlockedOff = "[ . ] Action Required | Create test.txt | drucial"
    static let codexIdle = "Create test.txt | drucial"
    static let codexBareIdle = "drucial"
    static let codexLaunch = "codex"
    static let codexRenaming = "⠴ renaming... ⠴ | drucial"
    static let claudeWorking = "◐ Multiple choice question tool"
    static let claudeWorkingAlternate = "◑ Multiple choice question tool"
    static let claudeIdle = "✳ Claude Code"
    static let claudeAsking = "✳ Create test.txt"
    static let claudeAnswered = "◐ Create test.txt"
}

enum AgentNotificationFixtures {
    static let claudeTitle = "Claude Code"
    static let claudePermission = "Claude needs your permission"
    static let claudeIdlePrompt = "Claude is waiting for your input"
}

final class AgentStateEngineTests: XCTestCase {
    private func codexState(_ title: String) -> AgentSignalState? {
        AgentStateEngine.evaluate(AgentRules.rules(for: "codex"), title: title, progress: "4;0").state
    }

    func test_everyCodexSpinnerFrame_readsWorking() {
        XCTAssertEqual(AgentTitleFixtures.codexWorking.count, 10, "the capture showed ten frames")
        for title in AgentTitleFixtures.codexWorking {
            XCTAssertEqual(codexState(title), .working, "\(title) is a spinner frame")
        }
    }

    func test_codexIdleTitles_readIdle() {
        for title in [AgentTitleFixtures.codexIdle, AgentTitleFixtures.codexBareIdle] {
            XCTAssertEqual(codexState(title), .idle, "\(title) is a finished turn")
        }
    }

    func test_bothHalvesOfCodexBlink_readBlocked() {
        let cases = [AgentTitleFixtures.codexBlockedOn, AgentTitleFixtures.codexBlockedOff]
        for title in cases {
            XCTAssertEqual(codexState(title), .blocked, "\(title) is the same prompt, mid-blink")
        }
    }

    func test_codexBareCWD_readsIdle() {
        XCTAssertEqual(codexState(AgentTitleFixtures.codexBareIdle), .idle)
    }

    func test_blocked_outranksWorking_whenBothMatch() {
        XCTAssertEqual(codexState("[ ! ] Action Required | ⠴ renaming... ⠴ | drucial"), .blocked)
    }

    func test_aTaskThatSaysActionRequired_isNotThePrompt() {
        XCTAssertEqual(codexState("⠹ Fix the Action Required banner | drucial"), .working)
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
            ("any needs one branch", .any([.contains("z"), .contains("b")]), "a b", true),
            ("any fails on all misses", .any([.contains("y"), .contains("z")]), "a b", false),
            ("any nests", .any([.contains("z"), .any([.contains("b")])]), "a b", true),
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
            AgentRules.message(fromTitle: AgentTitleFixtures.claudeWorkingAlternate, agentName: "claude"),
            "Multiple choice question tool")
    }

    func test_claudesIdleTitle_isNoMessage() {
        XCTAssertNil(
            AgentRules.message(fromTitle: AgentTitleFixtures.claudeIdle, agentName: "claude"),
            "it flickers in mid-turn, and \"Claude Code\" would replace the tool name")
    }

    func test_onlyClaudeTakesItsMessageFromTheTitle() {
        XCTAssertNil(AgentRules.message(fromTitle: AgentTitleFixtures.codexIdle, agentName: "codex"))
    }
}

final class AgentIdentificationTests: XCTestCase {
    func test_aTitleIdentifiesCodex() {
        let cases = [
            AgentTitleFixtures.codexLaunch, AgentTitleFixtures.codexBlockedOn,
            AgentTitleFixtures.codexBlockedOff, AgentTitleFixtures.codexWorking[0],
            AgentTitleFixtures.codexWorking[9], AgentTitleFixtures.codexRenaming,
        ]

        for title in cases {
            XCTAssertEqual(AgentRules.agentName(matching: title), "codex", "\(title)")
        }
    }

    func test_claudesLaunchTitle_identifiesClaude() {
        for title in [AgentTitleFixtures.claudeIdle, "◐ Claude Code"] {
            XCTAssertEqual(AgentRules.agentName(matching: title), "claude", "\(title)")
        }
    }

    func test_aTitleThatProvesNothing_identifiesNobody() {
        let cases = [
            AgentTitleFixtures.codexIdle, AgentTitleFixtures.codexBareIdle,
            AgentTitleFixtures.claudeWorking, "✳ Multiple choice question tool", "Claude Code",
            "~", "/Users/drucial", "npm run build", "",
            "Action Required: review the deploy", "vim Action Required.md",
            "⠋ π - drucial", "⠋ Claude Code",
        ]

        for title in cases {
            XCTAssertNil(AgentRules.agentName(matching: title), "\(title) is not proof of an agent")
        }
    }

    func test_claudesPermissionPrompt_asksForYou() {
        let body = AgentNotificationFixtures.claudePermission
        XCTAssertEqual(
            AgentRules.notificationAttention(body: body, agentName: AgentNotificationFixtures.claudeTitle), .waiting)
        XCTAssertEqual(AgentRules.notificationAttention(body: body, agentName: "claude"), .waiting)
    }

    func test_claudesIdlePrompt_carriesNoState() {
        XCTAssertNil(
            AgentRules.notificationAttention(
                body: AgentNotificationFixtures.claudeIdlePrompt, agentName: AgentNotificationFixtures.claudeTitle))
    }

    func test_anythingElseClaudePosts_closesATurn() {
        XCTAssertEqual(
            AgentRules.notificationAttention(
                body: "Refactor finished", agentName: AgentNotificationFixtures.claudeTitle),
            .completed)
    }

    func test_aBlockedCodexTitle_carriesItsAsk_inBothBlinkStates() {
        let captured = [
            "[ . ] Action Required | Approve writing test2.txt | zen-term",
            "[ ! ] Action Required | Approve writing test2.txt | zen-term",
        ]
        for title in captured {
            XCTAssertEqual(AgentRules.codexAsk(fromTitle: title), "Approve writing test2.txt", title)
        }
        XCTAssertEqual(
            AgentRules.codexAsk(fromTitle: "[ ! ] Action Required | Run cat a | wc | zen-term"), "Run cat a | wc")
    }

    func test_aTitleWithNoAsk_carriesNone() {
        for title in ["[ ! ] Action Required | zen-term", "[ . ] Action Required", "⠋ Approve writing | zen-term"] {
            XCTAssertNil(AgentRules.codexAsk(fromTitle: title), title)
        }
    }

    func test_aCodexNotification_carriesNoState() {
        XCTAssertNil(AgentRules.notificationAttention(body: "Approve writing test2.txt", agentName: "codex"))
    }

    func test_anAgentWithNoBodyRules_isTakenAtItsWord() {
        for name in ["pi", nil] as [String?] {
            XCTAssertEqual(
                AgentRules.notificationAttention(body: "Refactor finished", agentName: name), .waiting,
                "\(name ?? "an unnamed agent") has no rules to read its body by")
        }
    }
}
