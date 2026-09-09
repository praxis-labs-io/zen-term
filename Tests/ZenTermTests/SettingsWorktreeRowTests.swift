import AppKit
import XCTest

@testable import ZenTerm

/// The worktree rows under a workspace in Settings → Workspaces, and the Remove that hangs off them.
/// Mounted over real repos with real worktrees, because the listing is `git worktree list` and a
/// stub would assert the wiring rather than the rows.
final class SettingsWorktreeRowTests: WindowTestCase {
    private var tempRoot: URL!
    private var gitRoot: URL!
    private var window: NSWindow?
    private var section: SettingsWorkspacesSection?

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenterm-worktree-rows-\(UUID().uuidString)", isDirectory: true)
        gitRoot = tempRoot.appendingPathComponent("git", isDirectory: true)
        try FileManager.default.createDirectory(at: gitRoot, withIntermediateDirectories: true)
        ConfigLoader.defaultRootOverrideForTesting = tempRoot
        WorktreeStore.rootOverrideForTesting = tempRoot.appendingPathComponent(
            "worktrees", isDirectory: true)
        GitRepoStatus.resetForTesting()
    }

    override func tearDownWithError() throws {
        window = nil
        section = nil
        GitRepoStatus.resetForTesting()
        ConfigLoader.defaultRootOverrideForTesting = nil
        WorktreeStore.rootOverrideForTesting = nil
        try? FileManager.default.removeItem(at: tempRoot)
        try super.tearDownWithError()
    }

    // MARK: harness

    private func makeRepo(_ name: String) throws -> URL {
        let root = gitRoot.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return try GitFixture.makeRepoWithOrigin(under: root)
    }

    private func seed(_ text: String) throws {
        try text.write(
            to: tempRoot.appendingPathComponent("workspaces"), atomically: true, encoding: .utf8)
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    @discardableResult
    private func mount(_ section: SettingsWorkspacesSection) -> NSView {
        self.section = section
        let detail = section.makeDetailView()
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 500),
            styleMask: [.borderless], backing: .buffered, defer: false)
        win.contentView?.addSubview(detail)
        detail.frame = win.contentView!.bounds
        window = win
        return detail
    }

    private func workspaceRows(in view: NSView) -> [WorkspaceRow] {
        descendants(of: view).compactMap { $0 as? WorkspaceRow }
    }

    private func worktreeRows(in view: NSView) -> [WorktreeRow] {
        descendants(of: view).compactMap { $0 as? WorktreeRow }
    }

    /// The rows land in two passes: the `workspaces` file first, then two `git` calls per workspace.
    private func waitForWorktrees(_ detail: NSView, count: Int) {
        waitUntil(worktreeRows(in: detail).count == count, "\(count) worktree row(s) to land")
    }

    private func removeButton(in row: WorktreeRow) -> AppButton? {
        descendants(of: row).compactMap { $0 as? AppButton }.first
    }

    /// The row's own `⌫`, through the real key path rather than the handler behind it.
    private func pressDelete(on row: WorktreeRow) {
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, characters: "\u{8}", charactersIgnoringModifiers: "\u{8}", isARepeat: false,
            keyCode: 51)
        row.keyDown(with: event!)
    }

    // MARK: tests

    func test_listsAWorkspacesWorktreesUnderIt() throws {
        let repo = try makeRepo("app")
        _ = try WorktreeStore.create(branch: "feature/one", in: repo)
        _ = try WorktreeStore.create(branch: "feature/two", in: repo)
        try seed("[App]\npath = \(repo.path)\n")

        let detail = mount(SettingsWorkspacesSection())
        waitForWorktrees(detail, count: 2)
        XCTAssertEqual(
            worktreeRows(in: detail).map { $0.worktree.branch }, ["feature/one", "feature/two"])
        XCTAssertEqual(worktreeRows(in: detail).map { $0.parent.title }, ["App", "App"])
    }

    func test_aWorkspaceWithNoWorktrees_rendersNone() throws {
        let repo = try makeRepo("app")
        try seed("[App]\npath = \(repo.path)\n")

        let detail = mount(SettingsWorkspacesSection())
        waitUntil(!workspaceRows(in: detail).isEmpty, "the workspace row to land")
        XCTAssertEqual(worktreeRows(in: detail).count, 0)
    }

    /// A worktree the user has configured as a workspace of its own already has a row; repeating it
    /// as a child would put two Remove buttons on one folder. Its sibling still lists, which is what
    /// makes the absence an omission rather than a listing that never landed.
    ///
    /// `WorktreeGroupingTests` covers the ownership rules themselves; this is the section reading
    /// them.
    func test_aWorktreeConfiguredAsItsOwnWorkspace_isNotRepeated() throws {
        let repo = try makeRepo("app")
        let configured = try WorktreeStore.create(branch: "feature/one", in: repo)
        _ = try WorktreeStore.create(branch: "feature/two", in: repo)
        try seed("[App]\npath = \(repo.path)\n\n[One]\npath = \(configured.path.path)\n")

        let detail = mount(SettingsWorkspacesSection())
        waitForWorktrees(detail, count: 1)
        XCTAssertEqual(worktreeRows(in: detail).map { $0.worktree.branch }, ["feature/two"])
    }

    func test_theRemoveButton_routesOutWithTheWorktreeAndItsParent() throws {
        let repo = try makeRepo("app")
        try seed("[App]\npath = \(repo.path)\n")
        _ = try WorktreeStore.create(branch: "feature/one", in: repo)

        var asked: [(Worktree, Workspace)] = []
        let section = SettingsWorkspacesSection()
        section.onRemoveWorktree = { asked.append(($0, $1)) }
        let detail = mount(section)
        waitForWorktrees(detail, count: 1)

        let row = try XCTUnwrap(worktreeRows(in: detail).first)
        try XCTUnwrap(removeButton(in: row)).performClick(nil)

        XCTAssertEqual(asked.count, 1)
        XCTAssertEqual(asked.first?.0.branch, "feature/one")
        XCTAssertEqual(asked.first?.1.title, "App")
    }

    func test_deleteOnTheFocusedRow_removesIt() throws {
        let repo = try makeRepo("app")
        try seed("[App]\npath = \(repo.path)\n")
        _ = try WorktreeStore.create(branch: "feature/one", in: repo)

        var asked = 0
        let section = SettingsWorkspacesSection()
        section.onRemoveWorktree = { _, _ in asked += 1 }
        let detail = mount(section)
        waitForWorktrees(detail, count: 1)

        pressDelete(on: try XCTUnwrap(worktreeRows(in: detail).first))
        XCTAssertEqual(asked, 1)
    }

    /// A click on the row is focus and nothing else. A whole row that deletes what it names is one
    /// slip from a folder that is gone.
    func test_clickingTheRow_removesNothing() throws {
        let repo = try makeRepo("app")
        try seed("[App]\npath = \(repo.path)\n")
        _ = try WorktreeStore.create(branch: "feature/one", in: repo)

        var asked = 0
        let section = SettingsWorkspacesSection()
        section.onRemoveWorktree = { _, _ in asked += 1 }
        let detail = mount(section)
        waitForWorktrees(detail, count: 1)

        let row = try XCTUnwrap(worktreeRows(in: detail).first)
        let click = NSEvent.mouseEvent(
            with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        row.mouseDown(with: click!)
        XCTAssertEqual(asked, 0)
    }

    /// `WorktreeStore.remove` obeys a lock, so a Remove here would only ever fail.
    func test_aLockedWorktree_offersNoRemove() throws {
        let repo = try makeRepo("app")
        let worktree = try WorktreeStore.create(branch: "feature/one", in: repo)
        try GitFixture.run(["worktree", "lock", worktree.path.path], in: repo)
        try seed("[App]\npath = \(repo.path)\n")

        let detail = mount(SettingsWorkspacesSection())
        waitForWorktrees(detail, count: 1)

        let row = try XCTUnwrap(worktreeRows(in: detail).first)
        XCTAssertTrue(row.worktree.isLocked)
        XCTAssertNil(removeButton(in: row))
    }

    /// A second window's Settings can be looking at a worktree this one is already deleting.
    func test_aWorktreeAlreadyBeingRemoved_offersNoSecondRemove() throws {
        let repo = try makeRepo("app")
        let worktree = try WorktreeStore.create(branch: "feature/one", in: repo)
        try seed("[App]\npath = \(repo.path)\n")

        var asked = 0
        let section = SettingsWorkspacesSection()
        section.worktreeRemovals.begin(worktree.path)
        section.onRemoveWorktree = { _, _ in asked += 1 }
        let detail = mount(section)
        waitForWorktrees(detail, count: 1)

        let row = try XCTUnwrap(worktreeRows(in: detail).first)
        XCTAssertEqual(removeButton(in: row)?.isEnabled, false)
        pressDelete(on: row)
        XCTAssertEqual(asked, 0)
    }

    // MARK: traversal

    func test_arrowsWalkAWorkspaceIntoItsWorktreesAndOnToTheNext() throws {
        let first = try makeRepo("app")
        let second = try makeRepo("site")
        _ = try WorktreeStore.create(branch: "feature/one", in: first)
        try seed("[App]\npath = \(first.path)\n\n[Site]\npath = \(second.path)\n")

        let detail = mount(SettingsWorkspacesSection())
        waitForWorktrees(detail, count: 1)

        let stops = try XCTUnwrap(section).detailStops().map { stop -> String in
            if let row = stop as? WorkspaceRow { return "workspace:\(row.workspace.title)" }
            if let row = stop as? WorktreeRow { return "worktree:\(row.worktree.branch ?? "")" }
            return stop is AppButton ? "add" : "other"
        }
        XCTAssertEqual(stops, ["workspace:App", "worktree:feature/one", "workspace:Site", "add"])
    }

    /// ⌥↓ exchanges two `[Title]` blocks in the file, so it has to see workspaces alone: counting a
    /// worktree row as a neighbour would swap a workspace with something the file has no line for.
    func test_optionDown_reordersWorkspaces_pastTheWorktreeRowsBetweenThem() throws {
        let first = try makeRepo("app")
        let second = try makeRepo("site")
        _ = try WorktreeStore.create(branch: "feature/one", in: first)
        try seed("[App]\npath = \(first.path)\n\n[Site]\npath = \(second.path)\n")

        var swapped: [(String, String)] = []
        let section = SettingsWorkspacesSection()
        section.onReorder = { moved, with in
            swapped.append((moved.title, with.title))
            return true
        }
        let detail = mount(section)
        waitForWorktrees(detail, count: 1)

        let row = try XCTUnwrap(workspaceRows(in: detail).first)
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.option], timestamp: 0, windowNumber: 0,
            context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false,
            keyCode: 125)
        row.keyDown(with: event!)
        waitUntil(!swapped.isEmpty, "the reorder to run")

        XCTAssertEqual(swapped.map(\.0), ["App"])
        XCTAssertEqual(swapped.map(\.1), ["Site"])
    }
}
