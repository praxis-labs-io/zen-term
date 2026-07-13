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

    // MARK: update (ZEN-112)

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

    // MARK: remove (ZEN-112)

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
}
