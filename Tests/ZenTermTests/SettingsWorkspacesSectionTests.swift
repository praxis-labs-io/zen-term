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
    private func mount(_ section: SettingsWorkspacesSection, waitingForLoad: Bool = true) -> NSView {
        self.section = section
        let detail = section.makeDetailView()
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 500),
            styleMask: [.borderless], backing: .buffered, defer: false)
        win.contentView?.addSubview(detail)
        detail.frame = win.contentView!.bounds
        window = win
        if waitingForLoad { waitForLoad(in: detail) }
        return detail
    }

    /// The section reads the `workspaces` file off the main thread (ZEN-275), so a freshly mounted
    /// detail has neither rows nor the empty-state hint until the load lands. Either one appearing
    /// means it settled; waiting on rows alone would hang on an empty file.
    private func waitForLoad(in detail: NSView) {
        waitUntil(
            !rows(in: detail).isEmpty || emptyHint(in: detail) != nil,
            "the workspaces section to finish loading")
    }

    private func emptyHint(in view: NSView) -> NSTextField? {
        descendants(of: view).compactMap { $0 as? NSTextField }
            .first { $0.stringValue.hasPrefix("No workspaces yet") }
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

        // Each path is probed on its own, so wait for BOTH answers: a still-hidden badge on the plain
        // row would otherwise pass whether it had been answered or simply not reached yet.
        waitUntil(badge(inRowTitled: "Repo")?.isHidden == false, "the repo's git badge to land")
        waitUntil(GitRepoStatus.known(plain) != nil, "the plain folder to be answered too")

        XCTAssertNotNil(
            badge(inRowTitled: "Repo")?.image, "the badge renders the bundled git logo, not an empty view")
        XCTAssertEqual(badge(inRowTitled: "Plain")?.isHidden, true, "a plain folder keeps its badge hidden")
    }

    /// The rows arrive after the mount, and the empty-state hint is the answer for an empty FILE.
    /// Showing it while the read is still out tells the user their workspaces are gone, so the
    /// section renders neither until it knows.
    func test_whileLoading_showsNeitherRowsNorTheEmptyStateHint() throws {
        try seed(twoWorkspaces)

        let detail = mount(SettingsWorkspacesSection(), waitingForLoad: false)

        // Nothing has turned the run loop since the mount, so the load cannot have landed yet.
        XCTAssertTrue(rows(in: detail).isEmpty, "no rows before the file has been read")
        XCTAssertNil(emptyHint(in: detail), "and no 'no workspaces yet' hint for a file that has two")

        waitForLoad(in: detail)
        XCTAssertEqual(rows(in: detail).count, 2)
        XCTAssertNil(emptyHint(in: detail))
    }

    /// The rows land after the mount, and rebuilding tears the focused view out of the window, which
    /// makes AppKit reset first responder to the window itself: the focus ring vanishes and arrows,
    /// Tab and Return are dead until the user clicks. Reachable whenever the read is slow, which is
    /// the premise of loading it off the main thread at all.
    func test_focusSurvivesTheRowsLanding() throws {
        try seed(twoWorkspaces)
        let detail = mount(SettingsWorkspacesSection(), waitingForLoad: false)
        let window = try XCTUnwrap(self.window)
        let section = try XCTUnwrap(self.section)
        // Before the load the add button is the only stop, so that's what entering the detail lands on.
        XCTAssertTrue(window.makeFirstResponder(section.detailStops().first))

        waitForLoad(in: detail)

        let focused = window.firstResponder as? NSView
        XCTAssertTrue(
            section.detailStops().contains { $0 === focused },
            "focus must land on a stop once the rows arrive, not fall back to the window")
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
