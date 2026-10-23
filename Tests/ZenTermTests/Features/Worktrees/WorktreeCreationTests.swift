import XCTest

@testable import ZenTerm

final class WorktreeCreationTests: XCTestCase {
    private var root: URL!
    private var repo: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("worktree-creation-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        WorktreeStore.rootOverrideForTesting = root.appendingPathComponent("worktrees", isDirectory: true)
        repo = try GitFixture.makeRepo(at: root.appendingPathComponent("repo", isDirectory: true))
        try GitFixture.write("SECRET=1\n", to: repo.appendingPathComponent(".env"))
    }

    override func tearDownWithError() throws {
        WorktreeStore.rootOverrideForTesting = nil
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    private var target: RepoPickerOverlay.CreateTarget {
        RepoPickerOverlay.CreateTarget(
            workspace: Workspace(title: "Repo", path: repo, tabs: [], env: [:], carry: [".env", "missing"]),
            repo: repo)
    }

    private func create(
        _ request: NewWorktreeOverlay.Request, onPhase: ((String) -> Void)? = nil
    ) throws -> Result<WorktreeCreation.Created, Error> {
        var answer: Result<WorktreeCreation.Created, Error>?
        WorktreeCreation.start(request, from: target, onPhase: onPhase) { answer = $0 }
        waitUntil(answer != nil, "the create to finish", timeout: 10)
        return try XCTUnwrap(answer)
    }

    func test_reportsACopyPhasePerCarryEntry_andMirrorsTheEntry() throws {
        var phases: [String] = []

        let created = try create(.newBranch("feat/x", .defaultBranch), onPhase: { phases.append($0) }).get()

        waitUntil(phases.count == 2, "both phases to land on main")
        XCTAssertEqual(phases, ["Copying .env", "Copying missing"])
        XCTAssertEqual(created.workspace.title, "Repo: feat/x")
        XCTAssertEqual(created.origin.name, "feat/x")
        XCTAssertEqual(created.carry.carried, [".env"])
        XCTAssertTrue(GitFixture.exists(created.origin.path.appendingPathComponent(".env")))
    }

    func test_aFailureCarriesTheStoresError_andCreatesNothing() throws {
        let result = try create(.newBranch("feat..x", .defaultBranch))

        XCTAssertThrowsError(try result.get()) { error in
            XCTAssertEqual(error as? WorktreeStore.WorktreeError, .invalidBranchName("feat..x"))
        }
        XCTAssertEqual(try GitFixture.branches(in: repo), ["main"])
    }
}
