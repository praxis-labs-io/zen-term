import XCTest
@testable import ZenTerm

final class RepoScannerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("repo-scanner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeDir(_ name: String, git: Bool = false) throws {
        let dir = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if git {
            try FileManager.default.createDirectory(
                at: dir.appendingPathComponent(".git", isDirectory: true), withIntermediateDirectories: true)
        }
    }

    func test_listsOnlyDirectories_sortedCaseInsensitive() throws {
        try makeDir("zebra")
        try makeDir("Alpha")
        FileManager.default.createFile(atPath: root.appendingPathComponent("loose.txt").path, contents: nil)

        let names = RepoScanner.scan(root: root).map(\.name)
        XCTAssertEqual(names, ["Alpha", "zebra"])   // file excluded, case-insensitive order
    }

    func test_flagsGitRepos() throws {
        try makeDir("has-git", git: true)
        try makeDir("plain")

        let entries = RepoScanner.scan(root: root)
        XCTAssertEqual(entries.first(where: { $0.name == "has-git" })?.isGitRepo, true)
        XCTAssertEqual(entries.first(where: { $0.name == "plain" })?.isGitRepo, false)
    }

    func test_missingRoot_returnsEmpty() {
        let missing = root.appendingPathComponent("does-not-exist", isDirectory: true)
        XCTAssertEqual(RepoScanner.scan(root: missing), [])
    }
}
