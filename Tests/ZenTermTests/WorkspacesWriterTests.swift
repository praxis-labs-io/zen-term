import XCTest

@testable import ZenTerm

final class WorkspacesWriterTests: XCTestCase {
    private func expandTilde(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
    }

    private func assertRoundTrips(_ ws: Workspace, file: StaticString = #filePath, line: UInt = #line) {
        let parsed = WorkspacesParser.parse(WorkspacesWriter.serialize(ws))
        XCTAssertEqual(parsed.count, 1, "expected exactly one section", file: file, line: line)
        XCTAssertEqual(parsed.first, ws, file: file, line: line)
    }

    func test_minimalWorkspace_roundTrips() {
        assertRoundTrips(
            Workspace(
                title: "Scratch", path: expandTilde("~/Dev/scratch"),
                tabs: [], env: [:]))
    }

    func test_fullRecipe_roundTrips() {
        assertRoundTrips(
            Workspace(
                title: "ZenTerm", path: expandTilde("~/Dev/zen-term"),
                tabs: [Workspace.Tab(main: "nvim", right: "claude", bottom: "shell")],
                focus: Workspace.LaunchFocus(tab: 0, region: .right), env: [:]))
    }

    func test_env_roundTrips_regardlessOfKeyOrder() {
        assertRoundTrips(
            Workspace(
                title: "Web", path: expandTilde("~/Dev/web"),
                tabs: [Workspace.Tab(main: "nvim")],
                env: ["PORT": "3000", "NODE_ENV": "development", "API_URL": "http://localhost"]))
    }

    func test_spacedCommand_isQuoted_andRoundTrips() {
        let ws = Workspace(
            title: "Dev", path: expandTilde("~/Dev/app"),
            tabs: [Workspace.Tab(bottom: "npm run dev")], focus: Workspace.LaunchFocus(tab: 0, region: .bottom),
            env: [:])
        XCTAssertTrue(WorkspacesWriter.serialize(ws).contains("bottom = \"npm run dev\""))
        assertRoundTrips(ws)
    }

    func test_carry_roundTrips_inAuthoredOrder() {
        assertRoundTrips(
            Workspace(
                title: "ZenTerm", path: expandTilde("~/Dev/zen-term"),
                tabs: [], env: [:],
                carry: ["node_modules", ".env"]))
    }

    func test_carryWithSpace_isQuoted_andRoundTrips() {
        let ws = Workspace(
            title: "Spaced", path: expandTilde("~/Dev/spaced"),
            tabs: [], env: [:], carry: ["build output"])
        XCTAssertTrue(WorkspacesWriter.serialize(ws).contains("carry  = \"build output\""))
        assertRoundTrips(ws)
    }

    func test_envValueWithSpace_isQuoted_andRoundTrips() {
        let ws = Workspace(
            title: "Spaced", path: expandTilde("~/Dev/spaced"),
            tabs: [], env: ["GREETING": "hello world"])
        XCTAssertTrue(WorkspacesWriter.serialize(ws).contains("GREETING=\"hello world\""))
        assertRoundTrips(ws)
    }

    func test_absentFields_areOmitted() {
        let serialized = WorkspacesWriter.serialize(
            Workspace(
                title: "Bare", path: expandTilde("~/x"),
                tabs: [], env: [:]))
        func emitsKey(_ key: String) -> Bool {
            serialized.split(separator: "\n").contains { $0.hasPrefix(key) }
        }
        XCTAssertFalse(emitsKey("right"), "a closed drawer must not emit a `right =` line")
        XCTAssertFalse(emitsKey("main"))
        XCTAssertFalse(emitsKey("focus"), "the default focus (.main) is omitted")
    }

    func test_valueWithHash_isQuoted_andRoundTrips() {
        let ws = Workspace(
            title: "Hashy", path: expandTilde("~/Dev/hashy"),
            tabs: [Workspace.Tab(bottom: "echo # done")], env: ["TAG": "v1 #rc"])
        let serialized = WorkspacesWriter.serialize(ws)
        XCTAssertTrue(serialized.contains("\"echo # done\""))
        XCTAssertTrue(serialized.contains("TAG=\"v1 #rc\""))
        assertRoundTrips(ws)
    }

    func test_append_createsDirAndFile() throws {
        let root = tempDirPath()
        try WorkspacesWriter.append(
            Workspace(
                title: "First", path: expandTilde("~/Dev/first"),
                tabs: [Workspace.Tab(main: "nvim")], env: [:]),
            configRoot: root)
        XCTAssertEqual(ConfigLoader.loadWorkspacesBlocking(configRoot: root).map(\.title), ["First"])
    }

    func test_append_preservesExistingContentAndComments() throws {
        let root = try makeTempDir()
        let url = root.appendingPathComponent("workspaces")
        try "# my hand-written header\n[Existing]\npath = ~/Dev/existing\n"
            .write(to: url, atomically: true, encoding: .utf8)

        try WorkspacesWriter.append(
            Workspace(
                title: "Added", path: expandTilde("~/Dev/added"),
                tabs: [], env: [:]),
            configRoot: root)

        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("# my hand-written header"), "the comment survives")
        XCTAssertEqual(ConfigLoader.loadWorkspacesBlocking(configRoot: root).map(\.title), ["Existing", "Added"])
    }

    func test_append_unreadableExistingFile_throwsWithoutClobbering() throws {
        let root = try makeTempDir()
        let url = root.appendingPathComponent("workspaces")
        let invalidUTF8 = Data([0xFF, 0xFE, 0xFF])
        try invalidUTF8.write(to: url)

        let ws = Workspace(
            title: "New", path: expandTilde("~/Dev/new"),
            tabs: [], env: [:])
        XCTAssertThrowsError(try WorkspacesWriter.append(ws, configRoot: root))
        XCTAssertEqual(try Data(contentsOf: url), invalidUTF8, "the unreadable file must be left untouched")
    }

    func test_append_writesThroughSymlink() throws {
        let root = try makeTempDir()
        let target = try makeTempDir()
        let realFile = target.appendingPathComponent("workspaces-real")
        try "# dotfiles\n".write(to: realFile, atomically: true, encoding: .utf8)
        let link = root.appendingPathComponent("workspaces")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: realFile)

        try WorkspacesWriter.append(
            Workspace(
                title: "Linked", path: expandTilde("~/Dev/linked"),
                tabs: [], env: [:]),
            configRoot: root)

        let type = try FileManager.default.attributesOfItem(atPath: link.path)[.type] as? FileAttributeType
        XCTAssertEqual(type, .typeSymbolicLink, "the symlink must survive, not be replaced by a regular file")
        let written = try String(contentsOf: realFile, encoding: .utf8)
        XCTAssertTrue(written.contains("# dotfiles"), "the linked file's prior content survives")
        XCTAssertTrue(written.contains("[Linked]"), "the new section lands in the linked file")
    }

    func test_append_rejectsDuplicateTitle() throws {
        let root = tempDirPath()
        let ws = Workspace(
            title: "Dup", path: expandTilde("~/Dev/dup"),
            tabs: [], env: [:])
        try WorkspacesWriter.append(ws, configRoot: root)
        XCTAssertThrowsError(try WorkspacesWriter.append(ws, configRoot: root)) { error in
            guard case WorkspacesWriter.WriteError.titleExists("Dup") = error else {
                return XCTFail("expected titleExists, got \(error)")
            }
        }
        XCTAssertEqual(ConfigLoader.loadWorkspacesBlocking(configRoot: root).count, 1)
    }

    private func seed(_ text: String, in root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try text.write(to: root.appendingPathComponent("workspaces"), atomically: true, encoding: .utf8)
    }

    private func read(_ root: URL) throws -> String {
        try String(contentsOf: root.appendingPathComponent("workspaces"), encoding: .utf8)
    }

    func test_update_replacesSectionInPlace_preservingNeighboursAndComments() throws {
        let root = tempDirPath()
        try seed(
            """
            # my workspaces
            [Alpha]
            path = ~/Dev/alpha

            [Beta]
            path = ~/Dev/beta
            main = nvim

            [Gamma]
            path = ~/Dev/gamma
            """, in: root)

        try WorkspacesWriter.update(
            Workspace(
                title: "Beta", path: expandTilde("~/Dev/beta-moved"),
                tabs: [Workspace.Tab(main: "vim", right: "claude")], env: [:]),
            originalTitle: "Beta", configRoot: root)

        let parsed = ConfigLoader.loadWorkspacesBlocking(configRoot: root)
        XCTAssertEqual(parsed.map(\.title), ["Alpha", "Beta", "Gamma"])
        let beta = parsed.first { $0.title == "Beta" }
        XCTAssertEqual(beta?.path, expandTilde("~/Dev/beta-moved"))
        XCTAssertEqual(beta?.tabs[0].main, "vim")
        XCTAssertEqual(beta?.tabs[0].right, "claude")
        let text = try read(root)
        XCTAssertTrue(text.contains("# my workspaces"))
        XCTAssertTrue(text.contains("[Alpha]"))
        XCTAssertTrue(text.contains("[Gamma]"))
    }

    func test_update_renamesSection_movingItToTheNewTitle() throws {
        let root = tempDirPath()
        try seed("[Old]\npath = ~/Dev/old\n", in: root)

        try WorkspacesWriter.update(
            Workspace(
                title: "New", path: expandTilde("~/Dev/old"),
                tabs: [], env: [:]),
            originalTitle: "Old", configRoot: root)

        XCTAssertEqual(ConfigLoader.loadWorkspacesBlocking(configRoot: root).map(\.title), ["New"])
        XCTAssertFalse(try read(root).contains("[Old]"), "the old header is gone, not duplicated")
    }

    func test_update_renameOntoExistingTitle_throwsWithoutClobbering() throws {
        let root = tempDirPath()
        try seed("[A]\npath = ~/Dev/a\n\n[B]\npath = ~/Dev/b\n", in: root)

        XCTAssertThrowsError(
            try WorkspacesWriter.update(
                Workspace(
                    title: "B", path: expandTilde("~/Dev/a"),
                    tabs: [], env: [:]),
                originalTitle: "A", configRoot: root)
        ) { error in
            guard case WorkspacesWriter.WriteError.titleExists("B") = error else {
                return XCTFail("expected titleExists, got \(error)")
            }
        }
        XCTAssertEqual(ConfigLoader.loadWorkspacesBlocking(configRoot: root).map(\.title), ["A", "B"])
    }

    func test_update_handlesCRLFLineEndings_replacingInPlace() throws {
        let root = tempDirPath()
        try seed("[Alpha]\r\npath = ~/Dev/alpha\r\n\r\n[Beta]\r\npath = ~/Dev/beta\r\n", in: root)

        try WorkspacesWriter.update(
            Workspace(
                title: "Beta", path: expandTilde("~/Dev/beta-moved"),
                tabs: [], env: [:]),
            originalTitle: "Beta", configRoot: root)

        let text = try read(root)
        XCTAssertEqual(
            text.components(separatedBy: "[Beta]").count - 1, 1, "the section is replaced, not duplicated")
        XCTAssertEqual(ConfigLoader.loadWorkspacesBlocking(configRoot: root).map(\.title), ["Alpha", "Beta"])
    }

    func test_update_missingOriginal_fallsBackToAppend() throws {
        let root = tempDirPath()
        try seed("[A]\npath = ~/Dev/a\n", in: root)

        try WorkspacesWriter.update(
            Workspace(
                title: "Fresh", path: expandTilde("~/Dev/fresh"),
                tabs: [], env: [:]),
            originalTitle: "Ghost", configRoot: root)

        XCTAssertEqual(ConfigLoader.loadWorkspacesBlocking(configRoot: root).map(\.title), ["A", "Fresh"])
    }

    func test_remove_dropsSection_preservingNeighbours() throws {
        let root = tempDirPath()
        try seed(
            "[Alpha]\npath = ~/Dev/alpha\n\n[Beta]\npath = ~/Dev/beta\n\n[Gamma]\npath = ~/Dev/gamma\n",
            in: root)

        try WorkspacesWriter.remove(title: "Beta", configRoot: root)

        XCTAssertEqual(ConfigLoader.loadWorkspacesBlocking(configRoot: root).map(\.title), ["Alpha", "Gamma"])
        let text = try read(root)
        XCTAssertFalse(text.contains("[Beta]"))
        XCTAssertFalse(text.contains("\n\n\n"), "removing a middle section leaves no triple blank")
    }

    func test_remove_lastSection_leavesTheRest() throws {
        let root = tempDirPath()
        try seed("[Alpha]\npath = ~/Dev/alpha\n\n[Beta]\npath = ~/Dev/beta\n", in: root)

        try WorkspacesWriter.remove(title: "Beta", configRoot: root)

        XCTAssertEqual(ConfigLoader.loadWorkspacesBlocking(configRoot: root).map(\.title), ["Alpha"])
    }

    func test_remove_unknownTitle_isANoOp() throws {
        let root = tempDirPath()
        try seed("[Alpha]\npath = ~/Dev/alpha\n", in: root)

        try WorkspacesWriter.remove(title: "Ghost", configRoot: root)

        XCTAssertEqual(ConfigLoader.loadWorkspacesBlocking(configRoot: root).map(\.title), ["Alpha"])
    }

    private let threeSections = """
        [Alpha]
        path = ~/Dev/alpha

        [Beta]
        path = ~/Dev/beta
        main = nvim

        [Gamma]
        path = ~/Dev/gamma
        """

    func test_swap_exchangesTwoSectionPositions() throws {
        let root = tempDirPath()
        try seed(threeSections, in: root)

        XCTAssertTrue(try WorkspacesWriter.swap("Beta", with: "Alpha", configRoot: root))

        XCTAssertEqual(ConfigLoader.loadWorkspacesBlocking(configRoot: root).map(\.title), ["Beta", "Alpha", "Gamma"])
    }

    func test_swap_movesEachSectionsFieldsWithIt() throws {
        let root = tempDirPath()
        try seed(threeSections, in: root)

        XCTAssertTrue(try WorkspacesWriter.swap("Beta", with: "Alpha", configRoot: root))

        let parsed = ConfigLoader.loadWorkspacesBlocking(configRoot: root)
        XCTAssertEqual(parsed.first { $0.title == "Beta" }?.path, expandTilde("~/Dev/beta"))
        XCTAssertEqual(parsed.first { $0.title == "Beta" }?.tabs[0].main, "nvim")
        XCTAssertEqual(parsed.first { $0.title == "Alpha" }?.path, expandTilde("~/Dev/alpha"))
        XCTAssertNil(parsed.first { $0.title == "Alpha" }?.tabs[0].main)
    }

    func test_swap_handlesSectionsOfUnequalLength() throws {
        let root = tempDirPath()
        try seed(
            """
            [Short]
            path = ~/Dev/short

            [Long]
            path = ~/Dev/long
            main = nvim
            right = claude
            bottom = shell
            focus = right
            """, in: root)

        XCTAssertTrue(try WorkspacesWriter.swap("Long", with: "Short", configRoot: root))

        let parsed = ConfigLoader.loadWorkspacesBlocking(configRoot: root)
        XCTAssertEqual(parsed.map(\.title), ["Long", "Short"])
        XCTAssertEqual(parsed.first { $0.title == "Long" }?.tabs[0].right, "claude")
        XCTAssertEqual(parsed.first { $0.title == "Long" }?.focus, Workspace.LaunchFocus(tab: 0, region: .right))
        XCTAssertEqual(parsed.first { $0.title == "Short" }?.path, expandTilde("~/Dev/short"))
    }

    func test_swap_exchangesNonAdjacentSections() throws {
        let root = tempDirPath()
        try seed(threeSections, in: root)

        XCTAssertTrue(try WorkspacesWriter.swap("Gamma", with: "Alpha", configRoot: root))

        XCTAssertEqual(ConfigLoader.loadWorkspacesBlocking(configRoot: root).map(\.title), ["Gamma", "Beta", "Alpha"])
    }

    func test_swap_carriesACommentAttachedToItsHeader() throws {
        let root = tempDirPath()
        try seed(
            """
            # the one I actually work in
            [Alpha]
            path = ~/Dev/alpha

            # scratch space
            [Beta]
            path = ~/Dev/beta
            """, in: root)

        XCTAssertTrue(try WorkspacesWriter.swap("Beta", with: "Alpha", configRoot: root))

        let lines = try read(root).components(separatedBy: "\n")
        let betaHeader = try XCTUnwrap(lines.firstIndex(of: "[Beta]"))
        let alphaHeader = try XCTUnwrap(lines.firstIndex(of: "[Alpha]"))
        XCTAssertEqual(lines[betaHeader - 1], "# scratch space", "each comment follows its own section")
        XCTAssertEqual(lines[alphaHeader - 1], "# the one I actually work in")
        XCTAssertLessThan(betaHeader, alphaHeader, "and Beta really did move above Alpha")
    }

    func test_swap_leavesABlankSeparatedBannerAtTheTop() throws {
        let root = tempDirPath()
        try seed(
            """
            # zen-term workspaces — the ⌘⇧P project list.
            # See docs/config/workspaces for the field reference.

            [Alpha]
            path = ~/Dev/alpha

            [Beta]
            path = ~/Dev/beta
            """, in: root)

        XCTAssertTrue(try WorkspacesWriter.swap("Beta", with: "Alpha", configRoot: root))

        let lines = try read(root).components(separatedBy: "\n")
        XCTAssertEqual(lines.first, "# zen-term workspaces — the ⌘⇧P project list.")
        XCTAssertEqual(lines[1], "# See docs/config/workspaces for the field reference.")
        XCTAssertEqual(lines[3], "[Beta]", "the banner stays; only the sections below it move")
    }

    func test_swap_preservesTheBlankSeparators() throws {
        let root = tempDirPath()
        try seed(threeSections, in: root)
        let before = try read(root)

        XCTAssertTrue(try WorkspacesWriter.swap("Beta", with: "Alpha", configRoot: root))

        let after = try read(root)
        XCTAssertFalse(after.contains("\n\n\n"), "no doubled blank line")
        XCTAssertEqual(
            after.components(separatedBy: "\n").count, before.components(separatedBy: "\n").count,
            "a swap rearranges lines, it does not add or drop any")
    }

    func test_swap_handlesCRLFLineEndings() throws {
        let root = tempDirPath()
        try seed("[Alpha]\r\npath = ~/Dev/alpha\r\n\r\n[Beta]\r\npath = ~/Dev/beta\r\n", in: root)

        XCTAssertTrue(try WorkspacesWriter.swap("Beta", with: "Alpha", configRoot: root))

        XCTAssertEqual(ConfigLoader.loadWorkspacesBlocking(configRoot: root).map(\.title), ["Beta", "Alpha"])
    }

    func test_swap_unknownTitle_isANoOp_andReportsIt() throws {
        let root = tempDirPath()
        try seed(threeSections, in: root)
        let before = try read(root)

        XCTAssertFalse(try WorkspacesWriter.swap("Alpha", with: "Ghost", configRoot: root))

        XCTAssertEqual(try read(root), before, "a stale row must not rearrange the file")
    }

    private func threeTabs(focus: Workspace.LaunchFocus = .start) -> Workspace {
        Workspace(
            title: "ZenTerm", path: expandTilde("~/Dev/zen-term"),
            tabs: [
                Workspace.Tab(name: "nvim", main: "nvim", right: "claude"),
                Workspace.Tab(name: "the gate", bottom: "bin/check"),
                Workspace.Tab(main: "lazygit"),
            ],
            focus: focus, env: ["LOG_LEVEL": "debug"], carry: [".env"])
    }

    func test_singleUnnamedTab_writesTheFlatForm() {
        let ws = Workspace(
            title: "ZenTerm", path: expandTilde("~/Dev/zen-term"),
            tabs: [Workspace.Tab(main: "nvim", right: "claude", bottom: "shell")],
            focus: Workspace.LaunchFocus(tab: 0, region: .right), env: ["A": "1"], carry: [".env"])
        XCTAssertEqual(
            WorkspacesWriter.serialize(ws),
            """
            [ZenTerm]
            path   = ~/Dev/zen-term
            main   = nvim
            right  = claude
            bottom = shell
            focus  = right
            carry  = .env
            env    = A=1

            """)
    }

    func test_multipleTabs_writeWorkspaceKeysThenIndentedTabs() {
        XCTAssertEqual(
            WorkspacesWriter.serialize(threeTabs(focus: Workspace.LaunchFocus(tab: 1, region: .bottom))),
            """
            [ZenTerm]
            path   = ~/Dev/zen-term
            carry  = .env
            env    = LOG_LEVEL=debug

            tab = nvim
              main   = nvim
              right  = claude

            tab = "the gate"
              bottom = bin/check
              focus  = bottom

            tab
              main   = lazygit

            """)
    }

    func test_multipleTabs_roundTrip() {
        assertRoundTrips(threeTabs())
        assertRoundTrips(threeTabs(focus: Workspace.LaunchFocus(tab: 2, region: .right)))
    }

    func test_focusAtTheStart_isOmitted() {
        XCTAssertFalse(WorkspacesWriter.serialize(threeTabs()).contains("focus"))
    }

    func test_singleNamedTab_writesItsTabLine() {
        let ws = Workspace(
            title: "Solo", path: expandTilde("~/Dev/solo"), tabs: [Workspace.Tab(name: "editor", main: "nvim")],
            env: [:])
        let serialized = WorkspacesWriter.serialize(ws)
        XCTAssertTrue(serialized.contains("\ntab = editor\n  main   = nvim\n"))
        assertRoundTrips(ws)
    }

    func test_update_multiTabSection_keepsNeighboursAndSurroundingComments() throws {
        let root = tempDirPath()
        try seed(
            """
            # my workspaces
            [Alpha]
            path = ~/Dev/alpha

            # the main one
            [ZenTerm]
            path = ~/Dev/zen-term

            tab = old
              main = vim

            tab
              main = htop
            # trailing note

            [Gamma]
            path = ~/Dev/gamma
            """, in: root)

        try WorkspacesWriter.update(threeTabs(), originalTitle: "ZenTerm", configRoot: root)

        let parsed = ConfigLoader.loadWorkspacesBlocking(configRoot: root)
        XCTAssertEqual(parsed.map(\.title), ["Alpha", "ZenTerm", "Gamma"])
        XCTAssertEqual(parsed.first { $0.title == "ZenTerm" }, threeTabs())
        let text = try read(root)
        XCTAssertTrue(text.contains("# my workspaces\n[Alpha]"))
        XCTAssertTrue(text.contains("# the main one\n[ZenTerm]"))
        XCTAssertTrue(text.contains("  main   = lazygit\n# trailing note\n\n[Gamma]"))
        XCTAssertFalse(text.contains("htop"), "the old tabs are replaced, not left behind a blank line")
    }

    func test_remove_multiTabSection_takesItsTabsWithIt() throws {
        let root = tempDirPath()
        try seed(
            "[Alpha]\npath = ~/Dev/alpha\n\n" + WorkspacesWriter.serialize(threeTabs())
                + "\n[Gamma]\npath = ~/Dev/gamma\n", in: root)

        try WorkspacesWriter.remove(title: "ZenTerm", configRoot: root)

        XCTAssertEqual(ConfigLoader.loadWorkspacesBlocking(configRoot: root).map(\.title), ["Alpha", "Gamma"])
        XCTAssertFalse(try read(root).contains("tab"))
    }
}
