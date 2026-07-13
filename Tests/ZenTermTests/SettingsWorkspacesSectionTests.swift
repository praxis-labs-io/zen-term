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

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenterm-workspaces-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        ConfigLoader.defaultRootOverrideForTesting = tempRoot
    }

    override func tearDownWithError() throws {
        window = nil
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

    func test_gitRepoWorkspace_showsGitBadge_plainDoesNot() throws {
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
        XCTAssertNotNil(badge(inRowTitled: "Repo"), "a git-repo workspace shows the git badge")
        XCTAssertNil(badge(inRowTitled: "Plain"), "a plain folder shows no git badge")
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
