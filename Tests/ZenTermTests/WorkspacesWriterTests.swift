import XCTest

@testable import ZenTerm

final class WorkspacesWriterTests: XCTestCase {
    private func expandTilde(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenterm-writer-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    // MARK: serialize → parse round-trips

    /// The heart of the writer: whatever it emits must parse back to an equal `Workspace`.
    private func assertRoundTrips(_ ws: Workspace, file: StaticString = #filePath, line: UInt = #line) {
        let parsed = WorkspacesParser.parse(WorkspacesWriter.serialize(ws))
        XCTAssertEqual(parsed.count, 1, "expected exactly one section", file: file, line: line)
        XCTAssertEqual(parsed.first, ws, file: file, line: line)
    }

    func test_minimalWorkspace_roundTrips() {
        assertRoundTrips(
            Workspace(
                title: "Scratch", path: expandTilde("~/Dev/scratch"),
                main: nil, right: nil, bottom: nil, focus: .main, env: [:]))
    }

    func test_fullRecipe_roundTrips() {
        assertRoundTrips(
            Workspace(
                title: "ZenTerm", path: expandTilde("~/Dev/zen-term"),
                main: "nvim", right: "claude", bottom: "shell", focus: .right, env: [:]))
    }

    func test_cloneExclude_roundTrips_inAuthoredOrder() {
        assertRoundTrips(
            Workspace(
                title: "ZenTerm", path: expandTilde("~/Dev/zen-term"),
                main: nil, right: nil, bottom: nil, focus: .main, env: [:],
                cloneExclude: [".next", "tmp/scratch"]))
    }

    func test_cloneExcludeWithSpace_isQuoted_andRoundTrips() {
        assertRoundTrips(
            Workspace(
                title: "ZenTerm", path: expandTilde("~/Dev/zen-term"),
                main: nil, right: nil, bottom: nil, focus: .main, env: [:],
                cloneExclude: ["build output"]))
    }

    func test_env_roundTrips_regardlessOfKeyOrder() {
        assertRoundTrips(
            Workspace(
                title: "Web", path: expandTilde("~/Dev/web"),
                main: "nvim", right: nil, bottom: nil, focus: .main,
                env: ["PORT": "3000", "NODE_ENV": "development", "API_URL": "http://localhost"]))
    }

    func test_spacedCommand_isQuoted_andRoundTrips() {
        let ws = Workspace(
            title: "Dev", path: expandTilde("~/Dev/app"),
            main: nil, right: nil, bottom: "npm run dev", focus: .bottom, env: [:])
        XCTAssertTrue(WorkspacesWriter.serialize(ws).contains("bottom = \"npm run dev\""))
        assertRoundTrips(ws)
    }

    func test_envValueWithSpace_isQuoted_andRoundTrips() {
        let ws = Workspace(
            title: "Spaced", path: expandTilde("~/Dev/spaced"),
            main: nil, right: nil, bottom: nil, focus: .main, env: ["GREETING": "hello world"])
        XCTAssertTrue(WorkspacesWriter.serialize(ws).contains("GREETING=\"hello world\""))
        assertRoundTrips(ws)
    }

    func test_absentFields_areOmitted() {
        let serialized = WorkspacesWriter.serialize(
            Workspace(
                title: "Bare", path: expandTilde("~/x"),
                main: nil, right: nil, bottom: nil, focus: .main, env: [:]))
        // Check for the emitted key at the start of a line, so a coincidental substring in a path
        // or title can't false-pass (or false-fail) the "field omitted" assertion.
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
            main: nil, right: nil, bottom: "echo # done", focus: .main, env: ["TAG": "v1 #rc"])
        let serialized = WorkspacesWriter.serialize(ws)
        XCTAssertTrue(serialized.contains("\"echo # done\""))  // a whitespace-preceded # must be quoted
        XCTAssertTrue(serialized.contains("TAG=\"v1 #rc\""))
        assertRoundTrips(ws)  // the parser keeps the # only because it's inside quotes
    }

    // MARK: append

    func test_append_createsDirAndFile() throws {
        let root = try makeTempDir()  // does not exist yet
        try WorkspacesWriter.append(
            Workspace(
                title: "First", path: expandTilde("~/Dev/first"),
                main: "nvim", right: nil, bottom: nil, focus: .main, env: [:]),
            configRoot: root)
        XCTAssertEqual(ConfigLoader.loadWorkspaces(configRoot: root).map(\.title), ["First"])
    }

    func test_append_preservesExistingContentAndComments() throws {
        let root = try makeTempDir()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("workspaces")
        try "# my hand-written header\n[Existing]\npath = ~/Dev/existing\n"
            .write(to: url, atomically: true, encoding: .utf8)

        try WorkspacesWriter.append(
            Workspace(
                title: "Added", path: expandTilde("~/Dev/added"),
                main: nil, right: nil, bottom: nil, focus: .main, env: [:]),
            configRoot: root)

        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("# my hand-written header"), "the comment survives")
        XCTAssertEqual(ConfigLoader.loadWorkspaces(configRoot: root).map(\.title), ["Existing", "Added"])
    }

    func test_append_unreadableExistingFile_throwsWithoutClobbering() throws {
        let root = try makeTempDir()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("workspaces")
        let invalidUTF8 = Data([0xFF, 0xFE, 0xFF])  // not decodable as UTF-8 → the read must throw
        try invalidUTF8.write(to: url)

        let ws = Workspace(
            title: "New", path: expandTilde("~/Dev/new"),
            main: nil, right: nil, bottom: nil, focus: .main, env: [:])
        XCTAssertThrowsError(try WorkspacesWriter.append(ws, configRoot: root))
        XCTAssertEqual(try Data(contentsOf: url), invalidUTF8, "the unreadable file must be left untouched")
    }

    func test_append_writesThroughSymlink() throws {
        let root = try makeTempDir()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let target = try makeTempDir()
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let realFile = target.appendingPathComponent("workspaces-real")
        try "# dotfiles\n".write(to: realFile, atomically: true, encoding: .utf8)
        let link = root.appendingPathComponent("workspaces")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: realFile)

        try WorkspacesWriter.append(
            Workspace(
                title: "Linked", path: expandTilde("~/Dev/linked"),
                main: nil, right: nil, bottom: nil, focus: .main, env: [:]),
            configRoot: root)

        let type = try FileManager.default.attributesOfItem(atPath: link.path)[.type] as? FileAttributeType
        XCTAssertEqual(type, .typeSymbolicLink, "the symlink must survive, not be replaced by a regular file")
        let written = try String(contentsOf: realFile, encoding: .utf8)
        XCTAssertTrue(written.contains("# dotfiles"), "the linked file's prior content survives")
        XCTAssertTrue(written.contains("[Linked]"), "the new section lands in the linked file")
    }

    func test_append_rejectsDuplicateTitle() throws {
        let root = try makeTempDir()
        let ws = Workspace(
            title: "Dup", path: expandTilde("~/Dev/dup"),
            main: nil, right: nil, bottom: nil, focus: .main, env: [:])
        try WorkspacesWriter.append(ws, configRoot: root)
        XCTAssertThrowsError(try WorkspacesWriter.append(ws, configRoot: root)) { error in
            guard case WorkspacesWriter.WriteError.titleExists("Dup") = error else {
                return XCTFail("expected titleExists, got \(error)")
            }
        }
        // The rejected write left the file with a single section.
        XCTAssertEqual(ConfigLoader.loadWorkspaces(configRoot: root).count, 1)
    }

    // MARK: update

    private func seed(_ text: String, in root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try text.write(to: root.appendingPathComponent("workspaces"), atomically: true, encoding: .utf8)
    }

    private func read(_ root: URL) throws -> String {
        try String(contentsOf: root.appendingPathComponent("workspaces"), encoding: .utf8)
    }

    func test_update_replacesSectionInPlace_preservingNeighboursAndComments() throws {
        let root = try makeTempDir()
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
                main: "vim", right: "claude", bottom: nil, focus: .main, env: [:]),
            originalTitle: "Beta", configRoot: root)

        // Order preserved, only Beta changed.
        let parsed = ConfigLoader.loadWorkspaces(configRoot: root)
        XCTAssertEqual(parsed.map(\.title), ["Alpha", "Beta", "Gamma"])
        let beta = parsed.first { $0.title == "Beta" }
        XCTAssertEqual(beta?.path, expandTilde("~/Dev/beta-moved"))
        XCTAssertEqual(beta?.main, "vim")
        XCTAssertEqual(beta?.right, "claude")
        // The hand-written header comment and the untouched neighbours survive verbatim.
        let text = try read(root)
        XCTAssertTrue(text.contains("# my workspaces"))
        XCTAssertTrue(text.contains("[Alpha]"))
        XCTAssertTrue(text.contains("[Gamma]"))
    }

    func test_update_renamesSection_movingItToTheNewTitle() throws {
        let root = try makeTempDir()
        try seed("[Old]\npath = ~/Dev/old\n", in: root)

        try WorkspacesWriter.update(
            Workspace(
                title: "New", path: expandTilde("~/Dev/old"),
                main: nil, right: nil, bottom: nil, focus: .main, env: [:]),
            originalTitle: "Old", configRoot: root)

        XCTAssertEqual(ConfigLoader.loadWorkspaces(configRoot: root).map(\.title), ["New"])
        XCTAssertFalse(try read(root).contains("[Old]"), "the old header is gone, not duplicated")
    }

    func test_update_renameOntoExistingTitle_throwsWithoutClobbering() throws {
        let root = try makeTempDir()
        try seed("[A]\npath = ~/Dev/a\n\n[B]\npath = ~/Dev/b\n", in: root)

        // Renaming A → B would shadow the real B under last-wins; the writer must refuse.
        XCTAssertThrowsError(
            try WorkspacesWriter.update(
                Workspace(
                    title: "B", path: expandTilde("~/Dev/a"),
                    main: nil, right: nil, bottom: nil, focus: .main, env: [:]),
                originalTitle: "A", configRoot: root)
        ) { error in
            guard case WorkspacesWriter.WriteError.titleExists("B") = error else {
                return XCTFail("expected titleExists, got \(error)")
            }
        }
        XCTAssertEqual(ConfigLoader.loadWorkspaces(configRoot: root).map(\.title), ["A", "B"])
    }

    func test_update_handlesCRLFLineEndings_replacingInPlace() throws {
        let root = try makeTempDir()
        try seed("[Alpha]\r\npath = ~/Dev/alpha\r\n\r\n[Beta]\r\npath = ~/Dev/beta\r\n", in: root)

        try WorkspacesWriter.update(
            Workspace(
                title: "Beta", path: expandTilde("~/Dev/beta-moved"),
                main: nil, right: nil, bottom: nil, focus: .main, env: [:]),
            originalTitle: "Beta", configRoot: root)

        // With a stray `\r` defeating header detection, the edit would append a duplicate `[Beta]`
        // instead of replacing in place. Assert exactly one header survives.
        let text = try read(root)
        XCTAssertEqual(
            text.components(separatedBy: "[Beta]").count - 1, 1, "the section is replaced, not duplicated")
        XCTAssertEqual(ConfigLoader.loadWorkspaces(configRoot: root).map(\.title), ["Alpha", "Beta"])
    }

    func test_update_missingOriginal_fallsBackToAppend() throws {
        let root = try makeTempDir()
        try seed("[A]\npath = ~/Dev/a\n", in: root)

        try WorkspacesWriter.update(
            Workspace(
                title: "Fresh", path: expandTilde("~/Dev/fresh"),
                main: nil, right: nil, bottom: nil, focus: .main, env: [:]),
            originalTitle: "Ghost", configRoot: root)

        XCTAssertEqual(ConfigLoader.loadWorkspaces(configRoot: root).map(\.title), ["A", "Fresh"])
    }

    // MARK: remove

    func test_remove_dropsSection_preservingNeighbours() throws {
        let root = try makeTempDir()
        try seed(
            "[Alpha]\npath = ~/Dev/alpha\n\n[Beta]\npath = ~/Dev/beta\n\n[Gamma]\npath = ~/Dev/gamma\n",
            in: root)

        try WorkspacesWriter.remove(title: "Beta", configRoot: root)

        XCTAssertEqual(ConfigLoader.loadWorkspaces(configRoot: root).map(\.title), ["Alpha", "Gamma"])
        let text = try read(root)
        XCTAssertFalse(text.contains("[Beta]"))
        XCTAssertFalse(text.contains("\n\n\n"), "removing a middle section leaves no triple blank")
    }

    func test_remove_lastSection_leavesTheRest() throws {
        let root = try makeTempDir()
        try seed("[Alpha]\npath = ~/Dev/alpha\n\n[Beta]\npath = ~/Dev/beta\n", in: root)

        try WorkspacesWriter.remove(title: "Beta", configRoot: root)

        XCTAssertEqual(ConfigLoader.loadWorkspaces(configRoot: root).map(\.title), ["Alpha"])
    }

    func test_remove_unknownTitle_isANoOp() throws {
        let root = try makeTempDir()
        try seed("[Alpha]\npath = ~/Dev/alpha\n", in: root)

        try WorkspacesWriter.remove(title: "Ghost", configRoot: root)

        XCTAssertEqual(ConfigLoader.loadWorkspaces(configRoot: root).map(\.title), ["Alpha"])
    }

    // MARK: swap

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
        let root = try makeTempDir()
        try seed(threeSections, in: root)

        XCTAssertTrue(try WorkspacesWriter.swap("Beta", with: "Alpha", configRoot: root))

        XCTAssertEqual(ConfigLoader.loadWorkspaces(configRoot: root).map(\.title), ["Beta", "Alpha", "Gamma"])
    }

    /// Order is the only thing a swap may change. A section's fields riding along with its header is
    /// the whole point — a swap that moved headers alone would silently repoint every workspace at
    /// its neighbour's folder.
    func test_swap_movesEachSectionsFieldsWithIt() throws {
        let root = try makeTempDir()
        try seed(threeSections, in: root)

        XCTAssertTrue(try WorkspacesWriter.swap("Beta", with: "Alpha", configRoot: root))

        let parsed = ConfigLoader.loadWorkspaces(configRoot: root)
        XCTAssertEqual(parsed.first { $0.title == "Beta" }?.path, expandTilde("~/Dev/beta"))
        XCTAssertEqual(parsed.first { $0.title == "Beta" }?.main, "nvim")
        XCTAssertEqual(parsed.first { $0.title == "Alpha" }?.path, expandTilde("~/Dev/alpha"))
        XCTAssertNil(parsed.first { $0.title == "Alpha" }?.main)
    }

    /// Sections of unequal length: splicing the shorter block into the longer one's slot first would
    /// shift the indices under the second splice and shred both sections.
    func test_swap_handlesSectionsOfUnequalLength() throws {
        let root = try makeTempDir()
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

        let parsed = ConfigLoader.loadWorkspaces(configRoot: root)
        XCTAssertEqual(parsed.map(\.title), ["Long", "Short"])
        XCTAssertEqual(parsed.first { $0.title == "Long" }?.right, "claude")
        XCTAssertEqual(parsed.first { $0.title == "Long" }?.focus, .right)
        XCTAssertEqual(parsed.first { $0.title == "Short" }?.path, expandTilde("~/Dev/short"))
    }

    /// The two rows a user swaps need not be neighbours in the file — a shadowed duplicate section
    /// can sit between them — so the writer exchanges the two *named* blocks rather than moving one
    /// past whatever line happens to be adjacent.
    func test_swap_exchangesNonAdjacentSections() throws {
        let root = try makeTempDir()
        try seed(threeSections, in: root)

        XCTAssertTrue(try WorkspacesWriter.swap("Gamma", with: "Alpha", configRoot: root))

        XCTAssertEqual(ConfigLoader.loadWorkspaces(configRoot: root).map(\.title), ["Gamma", "Beta", "Alpha"])
    }

    /// A comment sitting directly on a header documents that workspace, so it travels with it —
    /// the convention `remove` already states when it refuses to swallow comments as separators.
    func test_swap_carriesACommentAttachedToItsHeader() throws {
        let root = try makeTempDir()
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

    /// A blank line below a comment block detaches it: the file's top banner documents the file, not
    /// the first section, and must not be dragged into the middle by the first reorder.
    func test_swap_leavesABlankSeparatedBannerAtTheTop() throws {
        let root = try makeTempDir()
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

    /// The blank separators belong to the file's shape, not to either block, so a swap must leave
    /// exactly as many as it found — no run-together sections, no growing gap per reorder.
    func test_swap_preservesTheBlankSeparators() throws {
        let root = try makeTempDir()
        try seed(threeSections, in: root)
        let before = try read(root)

        XCTAssertTrue(try WorkspacesWriter.swap("Beta", with: "Alpha", configRoot: root))

        let after = try read(root)
        XCTAssertFalse(after.contains("\n\n\n"), "no doubled blank line")
        XCTAssertEqual(
            after.components(separatedBy: "\n").count, before.components(separatedBy: "\n").count,
            "a swap rearranges lines, it does not add or drop any")
    }

    /// A `\r` left by a CRLF-editing tool defeats a naive `hasSuffix("]")` header check, which would
    /// leave the swap finding nothing and silently doing nothing.
    func test_swap_handlesCRLFLineEndings() throws {
        let root = try makeTempDir()
        try seed("[Alpha]\r\npath = ~/Dev/alpha\r\n\r\n[Beta]\r\npath = ~/Dev/beta\r\n", in: root)

        XCTAssertTrue(try WorkspacesWriter.swap("Beta", with: "Alpha", configRoot: root))

        XCTAssertEqual(ConfigLoader.loadWorkspaces(configRoot: root).map(\.title), ["Beta", "Alpha"])
    }

    /// A title that isn't in the file has to be reported, not just skipped: the caller re-renders its
    /// list on a `true`, so a silent no-op would leave the list showing an order the file never had.
    func test_swap_unknownTitle_isANoOp_andReportsIt() throws {
        let root = try makeTempDir()
        try seed(threeSections, in: root)
        let before = try read(root)

        XCTAssertFalse(try WorkspacesWriter.swap("Alpha", with: "Ghost", configRoot: root))

        XCTAssertEqual(try read(root), before, "a stale row must not rearrange the file")
    }
}
