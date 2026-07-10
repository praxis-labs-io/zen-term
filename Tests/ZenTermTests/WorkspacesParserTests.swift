import XCTest

@testable import ZenTerm

final class WorkspacesParserTests: XCTestCase {
    private func expandTilde(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
    }

    func test_fullSection_parsesEveryField() {
        let workspaces = WorkspacesParser.parse(
            """
            [ZenTerm]
            path   = ~/Dev/zen-term
            main   = nvim
            right  = claude
            bottom = shell
            focus  = right
            env    = NODE_ENV=development
            env    = PORT=3000
            """)
        XCTAssertEqual(workspaces.count, 1)
        let ws = workspaces[0]
        XCTAssertEqual(ws.title, "ZenTerm")
        XCTAssertEqual(ws.path, expandTilde("~/Dev/zen-term"))
        XCTAssertEqual(ws.main, "nvim")
        XCTAssertEqual(ws.right, "claude")
        XCTAssertEqual(ws.bottom, "shell")
        XCTAssertEqual(ws.focus, .right)
        XCTAssertEqual(ws.env, ["NODE_ENV": "development", "PORT": "3000"])
    }

    func test_minimalSection_pathOnly_defaultsMinimal() {
        let ws = WorkspacesParser.parse("[Scratch]\npath = ~/\n").first
        XCTAssertEqual(ws?.title, "Scratch")
        XCTAssertNil(ws?.main)  // absent → plain shell first pane
        XCTAssertNil(ws?.right)  // absent → drawer stays closed
        XCTAssertNil(ws?.bottom)
        XCTAssertEqual(ws?.focus, .main)  // default
        XCTAssertEqual(ws?.env, [:])
    }

    func test_missingPath_sectionDropped() {
        let workspaces = WorkspacesParser.parse(
            """
            [NoPath]
            main = nvim

            [HasPath]
            path = ~/Dev/wire
            """)
        XCTAssertEqual(workspaces.map(\.title), ["HasPath"])  // the pathless section is gone
    }

    func test_tildeExpansion() {
        let ws = WorkspacesParser.parse("[Home]\npath = ~/some/dir\n").first
        XCTAssertFalse(ws?.path.path.hasPrefix("~") ?? true)
        XCTAssertTrue(ws?.path.path.hasSuffix("/some/dir") ?? false)
    }

    func test_malformedEnv_skippedWithoutDroppingGoodOnes() {
        let ws = WorkspacesParser.parse(
            """
            [App]
            path = ~/Dev/app
            env  = GOOD=1
            env  = no_equals_here
            env  = =missingkey
            env  = ALSO=2
            """
        ).first
        XCTAssertEqual(ws?.env, ["GOOD": "1", "ALSO": "2"])
    }

    func test_envValue_mayContainEquals() {
        let ws = WorkspacesParser.parse("[X]\npath = ~/x\nenv = DSN=a=b=c\n").first
        XCTAssertEqual(ws?.env["DSN"], "a=b=c")  // only the first `=` splits key from value
    }

    func test_envValue_isTrimmedAndUnquoted() {
        let ws = WorkspacesParser.parse(
            """
            [X]
            path = ~/x
            env  = SPACED=  value
            env  = QUOTED="hello world"
            """
        ).first
        XCTAssertEqual(ws?.env["SPACED"], "value")  // leading whitespace after `=` trimmed
        XCTAssertEqual(ws?.env["QUOTED"], "hello world")  // surrounding quotes stripped
    }

    func test_emptyValue_treatedAsAbsent() {
        // `right =` with no value must not become a "" command that launches an empty program.
        let ws = WorkspacesParser.parse("[X]\npath = ~/x\nmain =\nright =\nfocus =\n").first
        XCTAssertNil(ws?.main)
        XCTAssertNil(ws?.right)
        XCTAssertEqual(ws?.focus, .main)  // empty focus → default, not a parse of ""
    }

    func test_inlineComments_andHashInsideQuotes() {
        let ws = WorkspacesParser.parse(
            """
            [C]                       # a workspace
            path   = ~/Dev/c          # the dir
            bottom = "echo # hi"
            """
        ).first
        XCTAssertEqual(ws?.path, expandTilde("~/Dev/c"))
        XCTAssertEqual(ws?.bottom, "echo # hi")  // `#` inside quotes survives comment-stripping
    }

    func test_quotedCommand_isUnquoted() {
        let ws = WorkspacesParser.parse("[D]\npath = ~/d\nbottom = \"npm run dev\"\n").first
        XCTAssertEqual(ws?.bottom, "npm run dev")
    }

    func test_invalidFocus_fallsBackToMain() {
        let ws = WorkspacesParser.parse("[E]\npath = ~/e\nfocus = sideways\n").first
        XCTAssertEqual(ws?.focus, .main)
    }

    func test_duplicateTitle_lastWins() {
        let workspaces = WorkspacesParser.parse(
            """
            [Dup]
            path = ~/first

            [Dup]
            path = ~/second
            """)
        XCTAssertEqual(workspaces.count, 1)
        XCTAssertEqual(workspaces.first?.path, expandTilde("~/second"))
    }

    func test_strayKeyBeforeAnyHeader_isIgnored() {
        let workspaces = WorkspacesParser.parse("path = ~/orphan\n[Real]\npath = ~/real\n")
        XCTAssertEqual(workspaces.map(\.title), ["Real"])
        XCTAssertEqual(workspaces.first?.path, expandTilde("~/real"))
    }

    func test_emptyHeader_ignored() {
        let workspaces = WorkspacesParser.parse("[]\npath = ~/nope\n[Ok]\npath = ~/ok\n")
        XCTAssertEqual(workspaces.map(\.title), ["Ok"])
    }
}
