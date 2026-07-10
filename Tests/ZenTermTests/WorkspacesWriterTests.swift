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
}
