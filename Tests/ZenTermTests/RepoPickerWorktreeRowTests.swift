import AppKit
import XCTest

@testable import ZenTerm

/// The ⌘P picker's worktree rows: a repo's linked worktrees indented under the workspace they
/// belong to. Real rows in a real window, driven through `setWorktrees` — the seam the background
/// listing delivers into — because a row that only exists in the model passes while it is dead.
final class RepoPickerWorktreeRowTests: WindowTestCase {
    /// Retained so a mounted overlay's window outlives the mount call.
    private var window: NSWindow?

    override func setUp() {
        super.setUp()
        GitRepoStatus.resetForTesting()
    }

    override func tearDown() {
        window = nil
        GitRepoStatus.resetForTesting()
        super.tearDown()
    }

    // MARK: rendering

    func test_worktrees_renderUnderTheirWorkspaceInListingOrder() {
        let repo = path("alpha")
        let overlay = makeRepoPicker(entries: [workspace("alpha", path: repo), workspace("beta")])
        mount(overlay)

        overlay.setWorktrees(listing(repo, "one", "two"), for: repo)

        XCTAssertEqual(
            shape(of: overlay),
            ["add", "workspace:alpha", "worktree:one", "worktree:two", "workspace:beta"])
    }

    /// Git names a worktree's branch when it lists it, so the row has it without waiting on the
    /// probe a workspace row waits on.
    func test_worktreeRow_showsItsOwnBranchWithoutAProbe() throws {
        let repo = path("alpha")
        let overlay = makeRepoPicker(entries: [workspace("alpha", path: repo)])
        mount(overlay)

        overlay.setWorktrees(listing(repo, "feature/zen-455"), for: repo)

        let row = try XCTUnwrap(rowViews(in: overlay)[2] as? RepoPickerOverlay.RowView)
        let title = row.worktree?.path.lastPathComponent
        let labels = descendants(of: row).compactMap { $0 as? NSTextField }
        XCTAssertEqual(title, "wt-feature-zen-455", "the folder is the branch's slug")
        XCTAssertEqual(
            labels.first { $0.stringValue != title }?.stringValue, "feature/zen-455",
            "the branch comes from the listing, not from a probe that has not run")
    }

    /// A detached worktree has no branch, and the row must not go blank where every other row
    /// carries a label.
    func test_detachedWorktree_fallsBackToTheProbe() {
        let repo = path("alpha")
        let overlay = makeRepoPicker(entries: [workspace("alpha", path: repo)])
        mount(overlay)

        let detached = Worktree(
            path: repo.appendingPathComponent("wt"), branch: nil, head: "abc1234", isLocked: false)
        overlay.setWorktrees(WorktreeListing(commonDir: repo, worktrees: [detached]), for: repo)

        XCTAssertEqual(shape(of: overlay), ["add", "workspace:alpha", "worktree:wt"])
    }

    // MARK: identity and reuse

    func test_worktreeRows_haveTheirOwnIdentityPerPath() {
        let repo = path("alpha")
        let overlay = makeRepoPicker(entries: [workspace("alpha", path: repo)])
        mount(overlay)
        overlay.setWorktrees(listing(repo, "one", "two"), for: repo)

        let ids = (0..<overlay.numberOfRows()).map { overlay.rowIdentity(at: $0) }
        XCTAssertEqual(Set(ids.compactMap { $0 }).count, ids.count, "every row needs a distinct identity")
    }

    /// A reused row keeps whatever it baked in, so identity is the path and a re-filter that leaves
    /// a worktree in place must hand back the same view.
    func test_worktreeRow_isReusedAcrossARefilter() {
        let repo = path("alpha")
        let overlay = makeRepoPicker(entries: [workspace("alpha", path: repo), workspace("beta")])
        mount(overlay)
        overlay.setWorktrees(listing(repo, "one"), for: repo)
        // [add, alpha, worktree one, beta] — the worktree row, not the last row.
        let before = rowViews(in: overlay)[2]

        type("alpha", into: overlay)

        XCTAssertEqual(shape(of: overlay), ["add", "workspace:alpha", "worktree:one"])
        XCTAssertTrue(rowViews(in: overlay)[2] === before, "the same worktree row, not a rebuild")
    }

    // MARK: filtering

    func test_filter_matchingAWorktreeKeepsItsWorkspaceRow() {
        let repo = path("alpha")
        let overlay = makeRepoPicker(entries: [workspace("alpha", path: repo), workspace("beta")])
        mount(overlay)
        overlay.setWorktrees(listing(repo, "hotfix"), for: repo)

        type("hotfix", into: overlay)

        XCTAssertEqual(
            shape(of: overlay), ["add", "workspace:alpha", "worktree:hotfix"],
            "a worktree row must never render orphaned")
    }

    func test_filter_matchingAWorkspaceKeepsAllItsWorktrees() {
        let repo = path("alpha")
        let overlay = makeRepoPicker(entries: [workspace("alpha", path: repo), workspace("beta")])
        mount(overlay)
        overlay.setWorktrees(listing(repo, "one", "two"), for: repo)

        type("alph", into: overlay)

        XCTAssertEqual(
            shape(of: overlay), ["add", "workspace:alpha", "worktree:one", "worktree:two"])
    }

    // MARK: activation

    func test_return_onAWorktreeOpensTheParentRecipeAtItsPath() {
        let repo = path("alpha")
        var chosen: (Workspace, Bool)?
        let parent = Workspace(
            title: "alpha", path: repo, main: "nvim", right: "claude", bottom: "shell",
            focus: .right, env: ["A": "1"], carry: [".env"])
        let overlay = makeRepoPicker(entries: [parent], onChoose: { chosen = ($0, $1) })
        mount(overlay)
        overlay.setWorktrees(listing(repo, "feature"), for: repo)

        overlay.activate(index: 2, modifiers: [])

        XCTAssertEqual(chosen?.0.title, "alpha: feature")
        XCTAssertEqual(chosen?.0.path.lastPathComponent, "wt-feature")
        XCTAssertEqual(chosen?.0.main, "nvim")
        XCTAssertEqual(chosen?.0.right, "claude")
        XCTAssertEqual(chosen?.0.bottom, "shell")
        XCTAssertEqual(chosen?.0.focus, .right)
        XCTAssertEqual(chosen?.0.env, ["A": "1"])
        XCTAssertEqual(chosen?.0.carry, [".env"])
        XCTAssertEqual(chosen?.1, false)
    }

    func test_shiftReturn_onAWorktreeReplacesTheCurrentTab() {
        let repo = path("alpha")
        var chosen: (Workspace, Bool)?
        let overlay = makeRepoPicker(
            entries: [workspace("alpha", path: repo)], onChoose: { chosen = ($0, $1) })
        mount(overlay)
        overlay.setWorktrees(listing(repo, "feature"), for: repo)

        overlay.activate(index: 2, modifiers: [.shift])

        XCTAssertEqual(chosen?.1, true)
    }

    // MARK: grouping

    /// The case the common dir exists for. Two workspaces that are checkouts of one repo get the
    /// same answer from `worktree list`, so the second must not repeat the first's children.
    func test_twoWorkspacesOfOneRepo_showTheWorktreesOnce() {
        let main = path("alpha")
        let inside = path("alpha-worktree")
        let shared = main.appendingPathComponent(".git")
        let overlay = makeRepoPicker(
            entries: [workspace("alpha", path: main), workspace("alpha wt", path: inside)])
        mount(overlay)

        let trees = [worktree(main, "one")]
        overlay.setWorktrees(WorktreeListing(commonDir: shared, worktrees: trees), for: main)
        overlay.setWorktrees(WorktreeListing(commonDir: shared, worktrees: trees), for: inside)

        XCTAssertEqual(
            shape(of: overlay), ["add", "workspace:alpha", "worktree:one", "workspace:alpha wt"])
    }

    /// Two unrelated repos each keep their own children: the claim is per common dir, not global.
    func test_twoRepos_eachKeepTheirOwnWorktrees() {
        let alpha = path("alpha")
        let beta = path("beta")
        let overlay = makeRepoPicker(
            entries: [workspace("alpha", path: alpha), workspace("beta", path: beta)])
        mount(overlay)

        overlay.setWorktrees(listing(alpha, "one"), for: alpha)
        overlay.setWorktrees(listing(beta, "two"), for: beta)

        XCTAssertEqual(
            shape(of: overlay),
            ["add", "workspace:alpha", "worktree:one", "workspace:beta", "worktree:two"])
    }

    /// A worktree the user configured as a workspace of its own already has a row. Repeating it as
    /// a child would put the same folder in the list twice.
    func test_aWorktreeThatIsAlreadyAWorkspace_isNotRepeated() {
        let repo = path("alpha")
        let tree = worktree(repo, "one")
        let overlay = makeRepoPicker(
            entries: [workspace("alpha", path: repo), workspace("one", path: tree.path)])
        mount(overlay)

        overlay.setWorktrees(WorktreeListing(commonDir: repo, worktrees: [tree]), for: repo)

        XCTAssertEqual(shape(of: overlay), ["add", "workspace:alpha", "workspace:one"])
    }

    // MARK: selection

    /// The listing lands while the card is already up. Rows inserted under the cursor must not
    /// take the highlight off the row the person is standing on.
    func test_rowsArrivingAfterTheCard_keepTheSelection() {
        let repo = path("alpha")
        let overlay = makeRepoPicker(
            entries: [workspace("alpha", path: repo), workspace("beta")])
        mount(overlay)
        send(#selector(NSResponder.moveDown(_:)), to: overlay)
        XCTAssertEqual(overlay.selected, 2, "standing on beta")

        overlay.setWorktrees(listing(repo, "one", "two"), for: repo)

        XCTAssertEqual(shape(of: overlay)[overlay.selected], "workspace:beta")
    }

    // MARK: helpers

    /// The list as it reads top to bottom, so an assertion names order and nesting in one line.
    private func shape(of overlay: RepoPickerOverlay) -> [String] {
        overlay.rowViews.map { view in
            guard let row = view as? RepoPickerOverlay.RowView else { return "add" }
            guard let worktree = row.worktree else { return "workspace:\(row.workspace.title)" }
            return "worktree:\(worktree.branch ?? worktree.path.lastPathComponent)"
        }
    }

    private func rowViews(in overlay: RepoPickerOverlay) -> [PaletteRowView] { overlay.rowViews }

    private func path(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("zenterm-wt-\(name)", isDirectory: true)
            .standardizedFileURL
    }

    /// A worktree of `repo`, laid out the way `WorktreeStore.create` lays one out: the branch's
    /// slug as the folder name, so a row's title and its branch are not the same string.
    private func worktree(_ repo: URL, _ branch: String) -> Worktree {
        Worktree(
            path: repo.deletingLastPathComponent()
                .appendingPathComponent("wt-\(WorktreeStore.slug(forText: branch))", isDirectory: true)
                .standardizedFileURL,
            branch: branch, head: "0000000", isLocked: false)
    }

    private func listing(_ repo: URL, _ branches: String...) -> WorktreeListing {
        WorktreeListing(
            commonDir: repo.appendingPathComponent(".git"),
            worktrees: branches.map { worktree(repo, $0) })
    }

    private func workspace(_ title: String, path: URL = FileManager.default.temporaryDirectory)
        -> Workspace
    {
        Workspace(title: title, path: path, main: nil, right: nil, bottom: nil, focus: .main, env: [:])
    }

    private func makeRepoPicker(
        entries: [Workspace], onChoose: @escaping (Workspace, Bool) -> Void = { _, _ in }
    ) -> RepoPickerOverlay {
        RepoPickerOverlay(
            entries: entries, background: Theme.current.chrome.background.nsColor,
            onChoose: onChoose, onAddWorkspace: {}, onDismiss: {})
    }

    private func makeWindow() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
            styleMask: [.borderless], backing: .buffered, defer: false)
    }

    @discardableResult
    private func mount(_ overlay: PaletteOverlay) -> NSWindow {
        overlay.translatesAutoresizingMaskIntoConstraints = true
        let window = makeWindow()
        window.contentView?.addSubview(overlay)
        overlay.frame = NSRect(x: 0, y: 0, width: 560, height: 420)
        self.window = window
        return window
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func searchField(in overlay: PaletteOverlay) -> NSTextField {
        descendants(of: overlay).compactMap { $0 as? NSTextField }
            .first { ($0.delegate as? PaletteOverlay) === overlay }!
    }

    private func type(_ query: String, into overlay: PaletteOverlay) {
        let field = searchField(in: overlay)
        field.stringValue = query
        overlay.controlTextDidChange(
            Notification(name: NSControl.textDidChangeNotification, object: field))
    }

    @discardableResult
    private func send(_ selector: Selector, to overlay: PaletteOverlay) -> Bool {
        overlay.control(searchField(in: overlay), textView: NSTextView(), doCommandBy: selector)
    }
}
