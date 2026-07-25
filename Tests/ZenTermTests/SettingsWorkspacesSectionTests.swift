import AppKit
import XCTest

@testable import ZenTerm

/// Interaction tests for the Workspaces settings section (ZEN-112): mount the real section over a
/// sandboxed `workspaces` file, assert it renders a row per configured workspace and that add / edit
/// route out through `onEditWorkspace`. Mirrors `SettingsToolsSectionTests`.
final class SettingsWorkspacesSectionTests: XCTestCase {
    /// Records the workspace `onEditWorkspace` was invoked with (`nil` = add).
    private final class EditSink {
        var calls: [Workspace?] = []
    }

    private var tempRoot: URL!
    private var window: NSWindow?
    /// The mounted section, retained the way the Settings card retains it while it's on screen —
    /// its rows update in place when the background git probe lands, and a released section would
    /// simply drop that.
    private var section: SettingsWorkspacesSection?

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenterm-workspaces-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        ConfigLoader.defaultRootOverrideForTesting = tempRoot
    }

    override func tearDownWithError() throws {
        window = nil
        section = nil
        ConfigLoader.defaultRootOverrideForTesting = nil
        try? FileManager.default.removeItem(at: tempRoot)
        try super.tearDownWithError()
    }

    // MARK: harness

    private func seed(_ text: String) throws {
        try text.write(to: tempRoot.appendingPathComponent("workspaces"), atomically: true, encoding: .utf8)
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

    private func rows(in view: NSView) -> [WorkspaceRow] {
        descendants(of: view).compactMap { $0 as? WorkspaceRow }
    }

    private let twoWorkspaces = """
        [Alpha]
        path = ~/Dev/alpha

        [Beta]
        path = ~/Dev/beta
        main = nvim
        """

    // MARK: tests

    func test_rendersRowPerConfiguredWorkspace() throws {
        try seed(twoWorkspaces)
        let detail = mount(SettingsWorkspacesSection())
        XCTAssertEqual(rows(in: detail).map(\.workspace.title), ["Alpha", "Beta"])
    }

    func test_emptyConfig_showsOnlyAddButtonStop() throws {
        try seed("")
        let section = SettingsWorkspacesSection()
        let detail = mount(section)
        XCTAssertTrue(rows(in: detail).isEmpty)
        XCTAssertEqual(section.detailStops().count, 1, "empty state exposes only the add button")
        XCTAssertTrue(section.detailStops().first is AppButton)
    }

    func test_addButton_invokesOnEditWorkspaceWithNil() throws {
        try seed(twoWorkspaces)
        let section = SettingsWorkspacesSection()
        let sink = EditSink()
        section.onEditWorkspace = { sink.calls.append($0) }
        _ = mount(section)

        (section.detailStops().last as? AppButton)?.onTap()

        XCTAssertEqual(sink.calls.count, 1)
        XCTAssertNil(sink.calls.first ?? nil, "the add button adds a new workspace (nil)")
    }

    /// The git probe runs off the main thread (ZEN-90), so a row mounts with its badge hidden and
    /// turns it on when the answer lands. That fill is exactly the kind of thing that can go
    /// silently dead — the probe returns and nothing updates — so the test observes the transition
    /// rather than priming the cache first.
    func test_gitRepoWorkspace_showsGitBadge_plainDoesNot() throws {
        GitRepoStatus.resetForTesting()
        // A real repo dir (has `.git`) and a plain dir, so `GitRepo.isGitRepo` is genuinely exercised.
        let repo = tempRoot.appendingPathComponent("repo", isDirectory: true)
        let plain = tempRoot.appendingPathComponent("plain", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        try Data().write(to: repo.appendingPathComponent(".git"))  // a worktree-style `.git` file
        try seed("[Repo]\npath = \(repo.path)\n\n[Plain]\npath = \(plain.path)\n")
        let detail = mount(SettingsWorkspacesSection())

        func badge(inRowTitled title: String) -> NSImageView? {
            let row = rows(in: detail).first { $0.workspace.title == title }!
            return descendants(of: row).compactMap { $0 as? NSImageView }.first
        }
        XCTAssertEqual(badge(inRowTitled: "Repo")?.isHidden, true, "nothing has probed the folder yet")

        waitUntil(badge(inRowTitled: "Repo")?.isHidden == false, "the repo's git badge to land")

        // Both paths are answered in one batch and applied together, so once the repo's badge is up
        // the plain folder's row has had its answer too.
        XCTAssertNotNil(
            badge(inRowTitled: "Repo")?.image, "the badge renders the bundled git logo, not an empty view")
        XCTAssertEqual(badge(inRowTitled: "Plain")?.isHidden, true, "a plain folder keeps its badge hidden")
    }

    func test_rowActivate_invokesOnEditWorkspaceWithThatWorkspace() throws {
        try seed(twoWorkspaces)
        let section = SettingsWorkspacesSection()
        let sink = EditSink()
        section.onEditWorkspace = { sink.calls.append($0) }
        let detail = mount(section)

        rows(in: detail).first { $0.workspace.title == "Beta" }?.onActivate?()

        XCTAssertEqual(sink.calls.first??.title, "Beta")
    }
}
