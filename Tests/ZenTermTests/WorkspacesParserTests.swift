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
        XCTAssertEqual(ws.tabs[0].main, "nvim")
        XCTAssertEqual(ws.tabs[0].right, "claude")
        XCTAssertEqual(ws.tabs[0].bottom, "shell")
        XCTAssertEqual(ws.focus, Workspace.LaunchFocus(tab: 0, region: .right))
        XCTAssertEqual(ws.env, ["NODE_ENV": "development", "PORT": "3000"])
    }

    func test_minimalSection_pathOnly_defaultsMinimal() {
        let ws = WorkspacesParser.parse("[Scratch]\npath = ~/\n").first
        XCTAssertEqual(ws?.title, "Scratch")
        XCTAssertNil(ws?.tabs[0].main)
        XCTAssertNil(ws?.tabs[0].right)
        XCTAssertNil(ws?.tabs[0].bottom)
        XCTAssertEqual(ws?.focus, .start)
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
        XCTAssertEqual(workspaces.map(\.title), ["HasPath"])
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
        XCTAssertEqual(ws?.env["DSN"], "a=b=c")
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
        XCTAssertEqual(ws?.env["SPACED"], "value")
        XCTAssertEqual(ws?.env["QUOTED"], "hello world")
    }

    func test_carry_isRepeatable_andKeepsAuthoredOrder() {
        let ws = WorkspacesParser.parse(
            """
            [ZenTerm]
            path  = ~/Dev/zen-term
            carry = node_modules
            carry = .env
            """
        ).first
        XCTAssertEqual(ws?.carry, ["node_modules", ".env"])
    }

    func test_carry_defaultsEmpty() {
        XCTAssertEqual(WorkspacesParser.parse("[Scratch]\npath = ~/\n").first?.carry, [])
    }

    func test_carry_dropsEntriesThatLeaveTheWorkspace() {
        let ws = WorkspacesParser.parse(
            """
            [ZenTerm]
            path  = ~/Dev/zen-term
            carry = ../sibling
            carry = /etc
            carry = ~/Documents
            carry = build/../../escape
            carry = .env
            """
        ).first
        XCTAssertEqual(ws?.carry, [".env"])
    }

    func test_carry_keepsANestedEntry() {
        let ws = WorkspacesParser.parse(
            """
            [ZenTerm]
            path  = ~/Dev/zen-term
            carry = config/credentials/development.key
            carry = .env
            """
        ).first
        XCTAssertEqual(ws?.carry, ["config/credentials/development.key", ".env"])
    }

    func test_carry_acceptsATrailingSlash() {
        let ws = WorkspacesParser.parse("[X]\npath = ~/x\ncarry = node_modules/\n").first
        XCTAssertEqual(ws?.carry, ["node_modules"])
    }

    func test_emptyCarryValue_treatedAsAbsent() {
        XCTAssertEqual(WorkspacesParser.parse("[Scratch]\npath = ~/\ncarry =\n").first?.carry, [])
    }

    func test_emptyValue_treatedAsAbsent() {
        let ws = WorkspacesParser.parse("[X]\npath = ~/x\nmain =\nright =\nfocus =\n").first
        XCTAssertNil(ws?.tabs[0].main)
        XCTAssertNil(ws?.tabs[0].right)
        XCTAssertEqual(ws?.focus, .start)
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
        XCTAssertEqual(ws?.tabs[0].bottom, "echo # hi")
    }

    func test_quotedCommand_isUnquoted() {
        let ws = WorkspacesParser.parse("[D]\npath = ~/d\nbottom = \"npm run dev\"\n").first
        XCTAssertEqual(ws?.tabs[0].bottom, "npm run dev")
    }

    func test_invalidFocus_fallsBackToMain() {
        let ws = WorkspacesParser.parse("[E]\npath = ~/e\nfocus = sideways\n").first
        XCTAssertEqual(ws?.focus, .start)
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

    func test_v130FlatSection_readsAsOneUnnamedTab() {
        let ws = WorkspacesParser.parse(
            """
            [ZenTerm]
            path   = ~/Dev/zen-term
            main   = nvim
            right  = claude
            bottom = shell
            focus  = bottom
            """
        ).first
        XCTAssertEqual(ws?.tabs, [Workspace.Tab(main: "nvim", right: "claude", bottom: "shell")])
        XCTAssertEqual(ws?.focus, Workspace.LaunchFocus(tab: 0, region: .bottom))
    }

    func test_namedTabs_ownTheKeysBelowThem() {
        let ws = WorkspacesParser.parse(
            """
            [ZenTerm]
            path = ~/Dev/zen-term

            tab = nvim
              main  = nvim
              right = claude

            tab = "the gate"
              bottom = bin/check
            """
        ).first
        XCTAssertEqual(
            ws?.tabs,
            [
                Workspace.Tab(name: "nvim", main: "nvim", right: "claude"),
                Workspace.Tab(name: "the gate", bottom: "bin/check"),
            ])
    }

    func test_bareTab_andEmptyTabName_startUnnamedTabs() {
        let ws = WorkspacesParser.parse(
            """
            [X]
            path = ~/x
            tab = editor
              main = nvim
            tab
              main = lazygit
            tab =
              main = htop
            """
        ).first
        XCTAssertEqual(
            ws?.tabs,
            [
                Workspace.Tab(name: "editor", main: "nvim"), Workspace.Tab(main: "lazygit"),
                Workspace.Tab(main: "htop"),
            ])
    }

    func test_tabWithNoKeys_isStillATab() {
        let ws = WorkspacesParser.parse("[X]\npath = ~/x\ntab = one\ntab = two\n").first
        XCTAssertEqual(ws?.tabs, [Workspace.Tab(name: "one"), Workspace.Tab(name: "two")])
    }

    func test_flatKeysBeforeTheFirstTab_makeAnImplicitFirstTab() {
        let ws = WorkspacesParser.parse(
            """
            [X]
            path = ~/x
            main = nvim
            tab = gate
              bottom = bin/check
            """
        ).first
        XCTAssertEqual(ws?.tabs, [Workspace.Tab(main: "nvim"), Workspace.Tab(name: "gate", bottom: "bin/check")])
    }

    func test_focusInsideATab_recordsThatTab() {
        let ws = WorkspacesParser.parse(
            """
            [X]
            path = ~/x
            tab = one
            tab = two
            tab = three
              right = claude
              focus = right
            """
        ).first
        XCTAssertEqual(ws?.focus, Workspace.LaunchFocus(tab: 2, region: .right))
    }

    func test_focusInMoreThanOneTab_lastWins() {
        let ws = WorkspacesParser.parse(
            """
            [X]
            path = ~/x
            tab = one
              focus = bottom
            tab = two
              focus = right
            tab = three
            """
        ).first
        XCTAssertEqual(ws?.focus, Workspace.LaunchFocus(tab: 1, region: .right))
    }

    func test_invalidFocusInsideATab_fallsBackToThatTabsMain() {
        let ws = WorkspacesParser.parse("[X]\npath = ~/x\ntab = one\ntab = two\n  focus = sideways\n").first
        XCTAssertEqual(ws?.focus, Workspace.LaunchFocus(tab: 1, region: .main))
    }

    func test_workspaceKeysAfterATab_stayWorkspaceLevel() {
        let ws = WorkspacesParser.parse(
            """
            [X]
            tab = one
              main = nvim
              env  = PORT=3000
              carry = .env
              path = ~/x
            tab = two
            """
        ).first
        XCTAssertEqual(ws?.path, expandTilde("~/x"))
        XCTAssertEqual(ws?.env, ["PORT": "3000"])
        XCTAssertEqual(ws?.carry, [".env"])
        XCTAssertEqual(ws?.tabs, [Workspace.Tab(name: "one", main: "nvim"), Workspace.Tab(name: "two")])
    }
}
