import AppKit
import XCTest

@testable import ZenTerm

/// The ⌘P picker's worktree rows: a repo's linked worktrees indented under the workspace they
/// belong to. Real rows in a real window, driven through `setWorktrees` — the seam the background
/// listing delivers into — because a row that only exists in the model passes while it is dead.
final class RepoPickerWorktreeRowTests: WindowTestCase {
    /// Retained so a mounted overlay's window outlives the mount call.
    private var window: NSWindow?

    /// Where "ours" is for this case, so an ordinary worktree is not reported as living somewhere
    /// odd. Real paths, never created on disk: nothing here touches the filesystem.
    private var worktreeRoot: URL!

    override func setUp() {
        super.setUp()
        // Pinned so a fading row resolves instantly and the machine's setting cannot decide a run.
        Motion.isReduceMotionEnabled = { true }
        worktreeRoot =
            FileManager.default.temporaryDirectory
            .appendingPathComponent("zenterm-wt-root-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        WorktreeStore.rootOverrideForTesting = worktreeRoot
        GitRepoStatus.resetForTesting()
    }

    override func tearDown() {
        window = nil
        WorktreeStore.rootOverrideForTesting = nil
        GitRepoStatus.resetForTesting()
        super.tearDown()
    }

    // MARK: the create hint follows the keymap

    func test_theCreateHint_readsTheChordFromTheLiveKeymap() {
        setKeymap([Chord(command: true, shift: true, key: "n"): .createWorktree])

        let hint = RepoPickerOverlay.footerHints().first { $0.label == "new worktree" }
        XCTAssertEqual(hint?.keys, "⌘⇧N")
    }

    /// Unbound in Settings, the hint would otherwise go on advertising a key that does nothing.
    func test_withTheActionUnbound_theHintIsGone() {
        setKeymap([:])

        let hints = RepoPickerOverlay.footerHints()
        XCTAssertNil(hints.first { $0.label == "new worktree" })
        XCTAssertEqual(hints.map(\.label), ["open", "replace", "move", "close"])
    }

    // MARK: what ⌥⏎ creates from

    func test_theCreateTarget_isNilOnTheAddRow() {
        let overlay = makeRepoPicker(entries: [workspace("alpha")])
        mount(overlay)

        XCTAssertEqual(shape(of: overlay)[overlay.selected], "workspace:alpha", "not on ＋ yet")
        send(#selector(NSResponder.moveUp(_:)), to: overlay)

        XCTAssertEqual(shape(of: overlay)[overlay.selected], "add")
        XCTAssertNil(overlay.createTarget)
    }

    func test_onAWorkspaceRow_theTargetIsThatWorkspaceAndItsOwnCheckout() throws {
        let repo = path("alpha")
        let overlay = makeRepoPicker(entries: [workspace("alpha", path: repo)])
        mount(overlay)

        let target = try XCTUnwrap(overlay.createTarget)

        XCTAssertEqual(target.workspace.title, "alpha")
        XCTAssertEqual(target.repo, repo)
    }

    /// The branch is cut from the row you can see; carry still comes from the parent, which is the
    /// checkout holding the install.
    func test_onAWorktreeRow_theBranchIsCutFromTheWorktreeAndCarryComesFromTheParent() throws {
        let repo = path("alpha")
        let parent = workspace("alpha", path: repo)
        let overlay = makeRepoPicker(entries: [parent])
        mount(overlay)
        overlay.setWorktrees(listing(repo, "feature/zen-455"), for: repo)
        send(#selector(NSResponder.moveDown(_:)), to: overlay)

        XCTAssertEqual(shape(of: overlay)[overlay.selected], "worktree:feature/zen-455")
        let target = try XCTUnwrap(overlay.createTarget)
        XCTAssertEqual(target.workspace.path, repo, "carry comes from the parent checkout")
        XCTAssertEqual(target.repo, worktree(repo, "feature/zen-455").path, "the base is the row")
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

    /// The left slot is a type, not a name. A worktree has no name: the branch belongs to the
    /// right column by the picker's own grammar, and the folder is either that branch's slug or a
    /// UUID, so the slot says what kind of row this is instead.
    func test_worktreeRow_readsAsAWorktreeOnTheLeftAndItsBranchOnTheRight() throws {
        let repo = path("alpha")
        let overlay = makeRepoPicker(entries: [workspace("alpha", path: repo)])
        mount(overlay)

        overlay.setWorktrees(listing(repo, "feature/zen-455"), for: repo)

        let row = try XCTUnwrap(rowViews(in: overlay)[2] as? RepoPickerOverlay.RowView)
        XCTAssertNotNil(label(in: row, saying: RepoPickerOverlay.RowView.typeRail))
        XCTAssertEqual(rightColumn(of: row), "feature/zen-455")
    }

    /// The proof the column means one thing at every depth: a workspace and its worktree put
    /// their branch in the same label, so the two right-align at one x.
    func test_branchSitsInTheSameColumnOnAWorkspaceAndAWorktree() throws {
        let repo = path("alpha")
        GitRepoStatus.resetForTesting()
        let overlay = makeRepoPicker(entries: [workspace("alpha", path: repo)])
        mount(overlay)
        overlay.setWorktrees(listing(repo, "one"), for: repo)

        let parent = try XCTUnwrap(rowViews(in: overlay)[1] as? RepoPickerOverlay.RowView)
        let child = try XCTUnwrap(rowViews(in: overlay)[2] as? RepoPickerOverlay.RowView)
        overlay.layoutSubtreeIfNeeded()
        let parentBranch = try XCTUnwrap(branchLabel(in: parent))
        let childBranch = try XCTUnwrap(branchLabel(in: child))
        XCTAssertEqual(
            parentBranch.convert(parentBranch.bounds, to: overlay).maxX,
            childBranch.convert(childBranch.bounds, to: overlay).maxX,
            accuracy: 0.5, "both branches end at the same trailing edge")
    }

    /// A type recedes further than a name does, which is what lets the child recede without
    /// spending an ink step that `.muted` already means elsewhere.
    func test_theTypeRail_isFainterAndSmallerThanAWorkspaceName() throws {
        let repo = path("alpha")
        let overlay = makeRepoPicker(entries: [workspace("alpha", path: repo)])
        mount(overlay)

        overlay.setWorktrees(listing(repo, "one"), for: repo)

        let parent = try XCTUnwrap(rowViews(in: overlay)[1] as? RepoPickerOverlay.RowView)
        let child = try XCTUnwrap(rowViews(in: overlay)[2] as? RepoPickerOverlay.RowView)
        let name = try XCTUnwrap(label(in: parent, saying: "alpha"))
        let rail = try XCTUnwrap(label(in: child, saying: RepoPickerOverlay.RowView.typeRail))
        XCTAssertEqual(name.textColor, Theme.current.chrome.foreground.nsColor)
        XCTAssertEqual(rail.textColor, Theme.current.chrome.ink(.faint))
        XCTAssertEqual(name.font?.pointSize, 13)
        XCTAssertEqual(rail.font?.pointSize, 11)
    }

    /// A detached worktree has no branch, and nothing probes a worktree path, so without the head
    /// git already handed us the column would be blank where every other row carries a value.
    func test_detachedWorktree_showsItsShortHeadInTheBranchColumn() throws {
        let repo = path("alpha")
        let overlay = makeRepoPicker(entries: [workspace("alpha", path: repo)])
        mount(overlay)

        let detached = Worktree(
            path: worktreeRoot.appendingPathComponent("alpha/loose", isDirectory: true), branch: nil,
            head: "abc1234def5678901234567890abcdef12345678", isLocked: false)
        overlay.setWorktrees(WorktreeListing(commonDir: repo, worktrees: [detached]), for: repo)

        let row = try XCTUnwrap(rowViews(in: overlay)[2] as? RepoPickerOverlay.RowView)
        XCTAssertEqual(rightColumn(of: row), "abc1234", "the same slot a branch would use")
    }

    /// A detached worktree's folder is named after whatever directory it was made in, which reads
    /// like a branch and is not one. The tab says what the row says.
    func test_detachedWorktree_opensATabNamedByItsHeadNotItsFolder() {
        let repo = path("alpha")
        var chosen: (Workspace, Bool)?
        let overlay = makeRepoPicker(
            entries: [workspace("alpha", path: repo)], onChoose: { chosen = ($0, $1) })
        mount(overlay)
        let detached = Worktree(
            path: worktreeRoot.appendingPathComponent("alpha/runbook-detached", isDirectory: true),
            branch: nil, head: "abc1234def5678901234567890abcdef12345678", isLocked: false)
        overlay.setWorktrees(WorktreeListing(commonDir: repo, worktrees: [detached]), for: repo)

        overlay.activate(index: 2, modifiers: [])

        XCTAssertEqual(chosen?.0.title, "alpha: abc1234")
    }

    private func label(in row: NSView, saying text: String) -> NSTextField? {
        descendants(of: row).compactMap { $0 as? NSTextField }.first { $0.stringValue == text }
    }

    /// The branch label, found by geometry rather than content: it is the right-aligned field
    /// furthest right, and its trailing edge is pinned whether or not a probe has filled it in.
    private func branchLabel(in row: NSView) -> NSTextField? {
        descendants(of: row).compactMap { $0 as? NSTextField }
            .filter { $0.alignment == .right }
            .max { $0.frame.maxX < $1.frame.maxX }
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
        XCTAssertEqual(chosen?.0.path.lastPathComponent, "feature")
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

    /// The counts arrive as an attributed value, which carries its own line behaviour, so the
    /// field's `lineBreakMode` does not reach them and a narrow row wrapped them out of its 32pt.
    func test_churnLabel_isCappedToOneLine() throws {
        let repo = path("alpha")
        let overlay = makeRepoPicker(entries: [workspace("alpha", path: repo)])
        mount(overlay)

        let row = try XCTUnwrap(rowViews(in: overlay)[1] as? RepoPickerOverlay.RowView)
        let clipping = descendants(of: row).compactMap { $0 as? NSTextField }
            .filter { $0.lineBreakMode == .byClipping }
        XCTAssertEqual(clipping.count, 1, "the churn label")
        XCTAssertEqual(clipping.first?.maximumNumberOfLines, 1)
    }

    // MARK: ownership

    /// A workspace inside a repo but not at its root resolves a common dir and lists nothing,
    /// because `isGitRepo` wants a `.git` entry. Claiming the group there hid the real checkout's
    /// worktrees entirely.
    func test_aWorkspaceThatListsNothing_doesNotClaimTheGroup() {
        let docs = path("repo-docs")
        let repo = path("repo")
        let shared = repo.appendingPathComponent(".git")
        let overlay = makeRepoPicker(
            entries: [workspace("Docs", path: docs), workspace("Repo", path: repo)])
        mount(overlay)

        overlay.setWorktrees(WorktreeListing(commonDir: shared, worktrees: []), for: docs)
        overlay.setWorktrees(
            WorktreeListing(commonDir: shared, worktrees: [worktree(repo, "one")]), for: repo)

        XCTAssertEqual(
            shape(of: overlay), ["add", "workspace:Docs", "workspace:Repo", "worktree:one"])
    }

    /// Ownership is decided from config order, never from the filtered list. `applyFilter` ranks
    /// prefix matches first and then alphabetically, so a query can inverse the configured order.
    /// Deciding ownership there moved the worktree to the other parent, and activating it opened
    /// that workspace's recipe at this worktree's path.
    func test_ownership_doesNotMoveWhenAFilterReordersTheList() throws {
        let owner = path("owner")
        let other = path("other")
        let shared = owner.appendingPathComponent(".git")
        var chosen: (Workspace, Bool)?
        // Config order puts "b-x" first; the query "x" prefixes neither, so "a-x" sorts ahead.
        let ownerWorkspace = Workspace(
            title: "b-x", path: owner, main: "nvim", right: nil, bottom: nil, focus: .main, env: [:])
        let overlay = makeRepoPicker(
            entries: [ownerWorkspace, workspace("a-x", path: other)],
            onChoose: { chosen = ($0, $1) })
        mount(overlay)
        let trees = [worktree(owner, "shared-branch")]
        overlay.setWorktrees(WorktreeListing(commonDir: shared, worktrees: trees), for: owner)
        overlay.setWorktrees(WorktreeListing(commonDir: shared, worktrees: trees), for: other)
        XCTAssertEqual(
            shape(of: overlay), ["add", "workspace:b-x", "worktree:shared-branch", "workspace:a-x"])

        type("x", into: overlay)

        XCTAssertEqual(
            shape(of: overlay), ["add", "workspace:a-x", "workspace:b-x", "worktree:shared-branch"],
            "the filter reorders the workspaces, and the worktree stays with b-x")
        let index = try XCTUnwrap(shape(of: overlay).firstIndex(of: "worktree:shared-branch"))
        overlay.activate(index: index, modifiers: [])
        XCTAssertEqual(chosen?.0.main, "nvim", "b-x's recipe, not a-x's")
    }

    /// A row you cannot find by the text it shows is a row you cannot find. A detached worktree
    /// renders its short head, so the head has to be searchable.
    func test_filter_findsADetachedWorktreeByItsShortHead() {
        let repo = path("alpha")
        let overlay = makeRepoPicker(
            entries: [workspace("alpha", path: repo), workspace("beta")])
        mount(overlay)
        let detached = Worktree(
            path: worktreeRoot.appendingPathComponent("alpha/loose", isDirectory: true), branch: nil,
            head: "abc1234def5678901234567890abcdef12345678", isLocked: false)
        overlay.setWorktrees(WorktreeListing(commonDir: repo, worktrees: [detached]), for: repo)

        type("abc1234", into: overlay)

        XCTAssertEqual(shape(of: overlay), ["add", "workspace:alpha", "worktree:abc1234"])
    }

    /// Announcing a commit as a branch tells a screen reader the repository is in a state it is not
    /// in.
    func test_accessibility_doesNotCallADetachedHeadABranch() {
        XCTAssertEqual(
            RepoPickerOverlay.RowView.headDescription("main", nil), "on branch main")
        let onBranch = Worktree(
            path: worktreeRoot, branch: "feature", head: "abc1234", isLocked: false)
        XCTAssertEqual(
            RepoPickerOverlay.RowView.headDescription("feature", onBranch),
            "worktree on branch feature")
        let detached = Worktree(path: worktreeRoot, branch: nil, head: "abc1234", isLocked: false)
        XCTAssertEqual(
            RepoPickerOverlay.RowView.headDescription("abc1234", detached),
            "worktree with a detached head at abc1234")
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

    // MARK: what ⌥⌫ removes from

    func test_theSelectedWorktree_isNilOnTheAddRow() {
        let overlay = makeRepoPicker(entries: [workspace("alpha")])
        mount(overlay)
        send(#selector(NSResponder.moveUp(_:)), to: overlay)

        XCTAssertEqual(shape(of: overlay)[overlay.selected], "add")
        XCTAssertNil(overlay.selectedWorktree)
    }

    /// A workspace is a checkout the user configured, not a worktree of ours, so ⌥⌫ over one has
    /// nothing to remove and does nothing.
    func test_theSelectedWorktree_isNilOnAWorkspaceRow() {
        let repo = path("alpha")
        let overlay = makeRepoPicker(entries: [workspace("alpha", path: repo)])
        mount(overlay)
        overlay.setWorktrees(listing(repo, "one"), for: repo)

        XCTAssertEqual(shape(of: overlay)[overlay.selected], "workspace:alpha")
        XCTAssertNil(overlay.selectedWorktree)
    }

    /// The parent comes along because the remove runs `git` in its checkout and its `carry` names
    /// what goes with the folder.
    func test_onAWorktreeRow_itNamesTheWorktreeAndItsParent() throws {
        let repo = path("alpha")
        let overlay = makeRepoPicker(entries: [workspace("alpha", path: repo)])
        mount(overlay)
        overlay.setWorktrees(listing(repo, "one", "two"), for: repo)
        send(#selector(NSResponder.moveDown(_:)), to: overlay)

        let selection = try XCTUnwrap(overlay.selectedWorktree)
        XCTAssertEqual(selection.worktree.branch, "one")
        XCTAssertEqual(selection.parent.title, "alpha")
    }

    // MARK: the remove hint follows the keymap

    func test_theRemoveHint_readsTheChordFromTheLiveKeymap() {
        setKeymap([Chord(option: true, key: "⌫"): .removeWorktree])

        let hint = RepoPickerOverlay.footerHints().first { $0.label == "remove worktree" }
        XCTAssertEqual(hint?.keys, "⌥⌫")
    }

    func test_withRemoveUnbound_theHintIsGone() {
        setKeymap([:])

        XCTAssertNil(RepoPickerOverlay.footerHints().first { $0.label == "remove worktree" })
    }

    // MARK: a worktree on its way out

    /// The folder is still on disk, so `worktree list` still reports it. The row has to say what is
    /// happening rather than reading as one you can open.
    func test_aWorktreeBeingRemoved_rendersAsRemoving() {
        let repo = path("alpha")
        let removals = WorktreeRemovalTracker()
        let overlay = makeRepoPicker(entries: [workspace("alpha", path: repo)], removals: removals)
        mount(overlay)
        removals.begin(worktree(repo, "one").path)

        overlay.setWorktrees(listing(repo, "one", "two"), for: repo)

        XCTAssertEqual(
            shape(of: overlay), ["add", "workspace:alpha", "removing:one", "worktree:two"])
    }

    /// Opening it would land a tab in a folder being deleted underneath it.
    func test_aWorktreeBeingRemoved_isSkippedByTheArrows() {
        let repo = path("alpha")
        let removals = WorktreeRemovalTracker()
        let overlay = makeRepoPicker(entries: [workspace("alpha", path: repo)], removals: removals)
        mount(overlay)
        removals.begin(worktree(repo, "one").path)
        overlay.setWorktrees(listing(repo, "one", "two"), for: repo)

        XCTAssertEqual(shape(of: overlay)[overlay.selected], "workspace:alpha")
        send(#selector(NSResponder.moveDown(_:)), to: overlay)

        XCTAssertEqual(shape(of: overlay)[overlay.selected], "worktree:two")
    }

    /// A picker open in another window when the delete starts is showing a row that just changed
    /// meaning, so the tracker has to reach it rather than only the next picker to open.
    func test_aRemovalStartingUnderAnOpenPicker_swapsTheRowInPlace() {
        let repo = path("alpha")
        let removals = WorktreeRemovalTracker()
        let overlay = makeRepoPicker(entries: [workspace("alpha", path: repo)], removals: removals)
        mount(overlay)
        overlay.setWorktrees(listing(repo, "one", "two"), for: repo)
        XCTAssertEqual(shape(of: overlay), ["add", "workspace:alpha", "worktree:one", "worktree:two"])

        removals.begin(worktree(repo, "one").path)
        overlay.refreshRemovalState()

        XCTAssertEqual(
            shape(of: overlay), ["add", "workspace:alpha", "removing:one", "worktree:two"])
    }

    /// Re-listing is what actually drops the row: the listings in hand still name the folder git
    /// has stopped reporting, so a re-render alone puts the ordinary row back for something gone.
    func test_relisting_dropsAWorktreeGitNoLongerReports() {
        let repo = path("alpha")
        let overlay = makeRepoPicker(entries: [workspace("alpha", path: repo)])
        mount(overlay)
        overlay.setWorktrees(listing(repo, "one", "two"), for: repo)

        overlay.setWorktrees(listing(repo, "two"), for: repo)

        XCTAssertEqual(shape(of: overlay), ["add", "workspace:alpha", "worktree:two"])
    }

    /// The delete failed, so the folder is still there and the row goes back to being one you can
    /// open. The `removed` case is the opposite, below.
    func test_aRemovalFailing_putsTheOrdinaryRowBack() {
        let repo = path("alpha")
        let removals = WorktreeRemovalTracker()
        let overlay = makeRepoPicker(entries: [workspace("alpha", path: repo)], removals: removals)
        mount(overlay)
        removals.begin(worktree(repo, "one").path)
        overlay.setWorktrees(listing(repo, "one", "two"), for: repo)

        removals.finish(worktree(repo, "one").path)
        overlay.refreshRemovalState()

        XCTAssertEqual(shape(of: overlay), ["add", "workspace:alpha", "worktree:one", "worktree:two"])
    }

    /// The claim is cleared before the picker hears about it, so re-rendering alone offers an
    /// ordinary row for a folder git has just deleted. Opening it lands a tab in nothing.
    func test_aRemovalThatLanded_takesTheRowOutBeforeTheRelist() {
        let repo = path("alpha")
        let removals = WorktreeRemovalTracker()
        let overlay = makeRepoPicker(entries: [workspace("alpha", path: repo)], removals: removals)
        mount(overlay)
        removals.begin(worktree(repo, "one").path)
        overlay.setWorktrees(listing(repo, "one", "two"), for: repo)

        removals.finish(worktree(repo, "one").path)
        overlay.dropWorktree(at: worktree(repo, "one").path)

        XCTAssertEqual(shape(of: overlay), ["add", "workspace:alpha", "worktree:two"])
    }

    // MARK: helpers

    /// The list as it reads top to bottom, so an assertion names order and nesting in one line.
    private func shape(of overlay: RepoPickerOverlay) -> [String] {
        overlay.rowViews.map { view in
            if let removing = view as? RepoPickerOverlay.RemovingRowView {
                return "removing:\(removing.name)"
            }
            guard let row = view as? RepoPickerOverlay.RowView else { return "add" }
            guard let worktree = row.worktree else { return "workspace:\(row.workspace.title)" }
            return "worktree:\(worktree.branch ?? String(worktree.head.prefix(7)))"
        }
    }

    private func rowViews(in overlay: RepoPickerOverlay) -> [PaletteRowView] { overlay.rowViews }

    private func path(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("zenterm-wt-\(name)", isDirectory: true)
            .standardizedFileURL
    }

    /// A worktree of `repo` where the app puts one, laid out the way `WorktreeStore.create` lays
    /// it out: the branch's slug as the folder name, so a row's name and its folder differ.
    private func worktree(_ repo: URL, _ branch: String) -> Worktree {
        Worktree(
            path:
                worktreeRoot
                .appendingPathComponent(repo.lastPathComponent, isDirectory: true)
                .appendingPathComponent(WorktreeStore.slug(forText: branch), isDirectory: true)
                .standardizedFileURL,
            branch: branch, head: "0000000", isLocked: false)
    }

    /// The right-hand column's value: the branch, or the short head on a detached worktree.
    private func rightColumn(of row: NSView) -> String? {
        descendants(of: row).compactMap { $0 as? NSTextField }
            .map(\.stringValue).filter { !$0.isEmpty }.dropFirst().first
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

    private func setKeymap(_ map: [Chord: KeyInterceptor.ReservedChord]) {
        let original = GeneralConfig.current
        var overridden = original
        overridden.keymap = map
        GeneralConfig.setCurrentForTesting(overridden)
        addTeardownBlock { GeneralConfig.setCurrentForTesting(original) }
    }

    private func makeRepoPicker(
        entries: [Workspace], removals: WorktreeRemovalTracker = WorktreeRemovalTracker(),
        onChoose: @escaping (Workspace, Bool) -> Void = { _, _ in }
    ) -> RepoPickerOverlay {
        RepoPickerOverlay(
            entries: entries, background: Theme.current.chrome.background.nsColor,
            removals: removals, onChoose: onChoose, onAddWorkspace: {}, onDismiss: {})
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
