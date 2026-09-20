import AppKit
import XCTest

@testable import ZenTerm

final class RepoPickerWorktreeRowTests: WindowTestCase {
    private var window: NSWindow?

    private var worktreeRoot: URL!

    override func setUp() {
        super.setUp()
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

    func test_theCreateHint_readsTheChordFromTheLiveKeymap() {
        setKeymap([Chord(command: true, shift: true, key: "n"): .createWorktree])

        let hint = RepoPickerOverlay.footerHints().first { $0.label == "new worktree" }
        XCTAssertEqual(hint?.keys, "⌘⇧N")
    }

    func test_withTheActionUnbound_theHintIsGone() {
        setKeymap([:])

        let hints = RepoPickerOverlay.footerHints()
        XCTAssertNil(hints.first { $0.label == "new worktree" })
        XCTAssertEqual(hints.map(\.label), ["open", "switch"])
    }

    func test_theCreateTarget_isNilOnTheActionRows() {
        let overlay = makeRepoPicker(entries: [workspace("alpha")])
        mount(overlay)

        XCTAssertEqual(shape(of: overlay)[overlay.selected], "workspace:alpha", "not on ＋ yet")
        send(#selector(NSResponder.moveDown(_:)), to: overlay)

        XCTAssertEqual(shape(of: overlay)[overlay.selected], "add")
        XCTAssertNil(overlay.createTarget)

        send(#selector(NSResponder.moveUp(_:)), to: overlay)
        send(#selector(NSResponder.moveUp(_:)), to: overlay)

        XCTAssertEqual(shape(of: overlay)[overlay.selected], "new")
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

    func test_worktrees_renderUnderTheirWorkspaceInListingOrder() {
        let repo = path("alpha")
        let overlay = makeRepoPicker(entries: [workspace("alpha", path: repo), workspace("beta")])
        mount(overlay)

        overlay.setWorktrees(listing(repo, "one", "two"), for: repo)

        XCTAssertEqual(
            shape(of: overlay),
            ["new", "workspace:alpha", "worktree:one", "worktree:two", "workspace:beta", "add"])
    }

    func test_worktreeRow_readsAsAWorktreeOnTheLeftAndItsBranchOnTheRight() throws {
        let repo = path("alpha")
        let overlay = makeRepoPicker(entries: [workspace("alpha", path: repo)])
        mount(overlay)

        overlay.setWorktrees(listing(repo, "feature/zen-455"), for: repo)

        let row = try XCTUnwrap(rowViews(in: overlay)[2] as? RepoPickerOverlay.RowView)
        XCTAssertNotNil(label(in: row, saying: RepoPickerOverlay.RowView.typeRail))
        XCTAssertEqual(rightColumn(of: row), "feature/zen-455")
    }

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

    func test_detachedWorktree_opensATabNamedByItsHeadNotItsFolder() {
        let repo = path("alpha")
        var chosen: Workspace?
        let overlay = makeRepoPicker(
            entries: [workspace("alpha", path: repo)], onChoose: { ws, _ in chosen = ws })
        mount(overlay)
        let detached = Worktree(
            path: worktreeRoot.appendingPathComponent("alpha/runbook-detached", isDirectory: true),
            branch: nil, head: "abc1234def5678901234567890abcdef12345678", isLocked: false)
        overlay.setWorktrees(WorktreeListing(commonDir: repo, worktrees: [detached]), for: repo)

        overlay.activate(index: 2, modifiers: [])

        XCTAssertEqual(chosen?.title, "alpha: abc1234")
    }

    private func label(in row: NSView, saying text: String) -> NSTextField? {
        descendants(of: row).compactMap { $0 as? NSTextField }.first { $0.stringValue == text }
    }

    private func branchLabel(in row: NSView) -> NSTextField? {
        descendants(of: row).compactMap { $0 as? NSTextField }
            .filter { $0.alignment == .right }
            .max { $0.frame.maxX < $1.frame.maxX }
    }

    func test_worktreeRows_haveTheirOwnIdentityPerPath() {
        let repo = path("alpha")
        let overlay = makeRepoPicker(entries: [workspace("alpha", path: repo)])
        mount(overlay)
        overlay.setWorktrees(listing(repo, "one", "two"), for: repo)

        let ids = (0..<overlay.numberOfRows()).map { overlay.rowIdentity(at: $0) }
        XCTAssertEqual(Set(ids.compactMap { $0 }).count, ids.count, "every row needs a distinct identity")
    }

    func test_worktreeRow_isReusedAcrossARefilter() {
        let repo = path("alpha")
        let overlay = makeRepoPicker(entries: [workspace("alpha", path: repo), workspace("beta")])
        mount(overlay)
        overlay.setWorktrees(listing(repo, "one"), for: repo)
        let before = rowViews(in: overlay)[2]

        type("alpha", into: overlay)

        XCTAssertEqual(shape(of: overlay), ["new", "workspace:alpha", "worktree:one", "add"])
        XCTAssertTrue(rowViews(in: overlay)[2] === before, "the same worktree row, not a rebuild")
    }

    func test_filter_matchingAWorktreeKeepsItsWorkspaceRow() {
        let repo = path("alpha")
        let overlay = makeRepoPicker(entries: [workspace("alpha", path: repo), workspace("beta")])
        mount(overlay)
        overlay.setWorktrees(listing(repo, "hotfix"), for: repo)

        type("hotfix", into: overlay)

        XCTAssertEqual(
            shape(of: overlay), ["new", "workspace:alpha", "worktree:hotfix", "add"],
            "a worktree row must never render orphaned")
    }

    func test_filter_matchingAWorkspaceKeepsAllItsWorktrees() {
        let repo = path("alpha")
        let overlay = makeRepoPicker(entries: [workspace("alpha", path: repo), workspace("beta")])
        mount(overlay)
        overlay.setWorktrees(listing(repo, "one", "two"), for: repo)

        type("alph", into: overlay)

        XCTAssertEqual(
            shape(of: overlay), ["new", "workspace:alpha", "worktree:one", "worktree:two", "add"])
    }

    func test_return_onAWorktreeOpensTheParentRecipeAtItsPath() {
        let repo = path("alpha")
        var chosen: Workspace?
        let parent = Workspace(
            title: "alpha", path: repo, main: "nvim", right: "claude", bottom: "shell",
            focus: .right, env: ["A": "1"], carry: [".env"])
        let overlay = makeRepoPicker(entries: [parent], onChoose: { ws, _ in chosen = ws })
        mount(overlay)
        overlay.setWorktrees(listing(repo, "feature"), for: repo)

        overlay.activate(index: 2, modifiers: [])

        XCTAssertEqual(chosen?.title, "alpha: feature")
        XCTAssertEqual(chosen?.path.lastPathComponent, "feature")
        XCTAssertEqual(chosen?.main, "nvim")
        XCTAssertEqual(chosen?.right, "claude")
        XCTAssertEqual(chosen?.bottom, "shell")
        XCTAssertEqual(chosen?.focus, .right)
        XCTAssertEqual(chosen?.env, ["A": "1"])
        XCTAssertEqual(chosen?.carry, [".env"])
    }

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
            shape(of: overlay), ["new", "workspace:alpha", "worktree:one", "workspace:alpha wt", "add"])
    }

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
            ["new", "workspace:alpha", "worktree:one", "workspace:beta", "worktree:two", "add"])
    }

    func test_aWorktreeThatIsAlreadyAWorkspace_isNotRepeated() {
        let repo = path("alpha")
        let tree = worktree(repo, "one")
        let overlay = makeRepoPicker(
            entries: [workspace("alpha", path: repo), workspace("one", path: tree.path)])
        mount(overlay)

        overlay.setWorktrees(WorktreeListing(commonDir: repo, worktrees: [tree]), for: repo)

        XCTAssertEqual(shape(of: overlay), ["new", "workspace:alpha", "workspace:one", "add"])
    }

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
            shape(of: overlay), ["new", "workspace:Docs", "workspace:Repo", "worktree:one", "add"])
    }

    func test_ownership_doesNotMoveWhenAFilterReordersTheList() throws {
        let owner = path("owner")
        let other = path("other")
        let shared = owner.appendingPathComponent(".git")
        var chosen: Workspace?
        let ownerWorkspace = Workspace(
            title: "b-x", path: owner, main: "nvim", right: nil, bottom: nil, focus: .main, env: [:])
        let overlay = makeRepoPicker(
            entries: [ownerWorkspace, workspace("a-x", path: other)],
            onChoose: { ws, _ in chosen = ws })
        mount(overlay)
        let trees = [worktree(owner, "shared-branch")]
        overlay.setWorktrees(WorktreeListing(commonDir: shared, worktrees: trees), for: owner)
        overlay.setWorktrees(WorktreeListing(commonDir: shared, worktrees: trees), for: other)
        XCTAssertEqual(
            shape(of: overlay), ["new", "workspace:b-x", "worktree:shared-branch", "workspace:a-x", "add"])

        type("x", into: overlay)

        XCTAssertEqual(
            shape(of: overlay), ["new", "workspace:a-x", "workspace:b-x", "worktree:shared-branch", "add"],
            "the filter reorders the workspaces, and the worktree stays with b-x")
        let index = try XCTUnwrap(shape(of: overlay).firstIndex(of: "worktree:shared-branch"))
        overlay.activate(index: index, modifiers: [])
        XCTAssertEqual(chosen?.main, "nvim", "b-x's recipe, not a-x's")
    }

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

        XCTAssertEqual(shape(of: overlay), ["new", "workspace:alpha", "worktree:abc1234", "add"])
    }

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

    func test_theSelectedWorktree_isNilOnTheAddRow() {
        let overlay = makeRepoPicker(entries: [workspace("alpha")])
        mount(overlay)
        send(#selector(NSResponder.moveDown(_:)), to: overlay)

        XCTAssertEqual(shape(of: overlay)[overlay.selected], "add")
        XCTAssertNil(overlay.selectedWorktree)
    }

    func test_theSelectedWorktree_isNilOnAWorkspaceRow() {
        let repo = path("alpha")
        let overlay = makeRepoPicker(entries: [workspace("alpha", path: repo)])
        mount(overlay)
        overlay.setWorktrees(listing(repo, "one"), for: repo)

        XCTAssertEqual(shape(of: overlay)[overlay.selected], "workspace:alpha")
        XCTAssertNil(overlay.selectedWorktree)
    }

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

    func test_theRemoveHint_readsTheChordFromTheLiveKeymap() {
        setKeymap([Chord(option: true, key: "⌫"): .removeWorktree])

        let hint = RepoPickerOverlay.footerHints().first { $0.label == "remove worktree" }
        XCTAssertEqual(hint?.keys, "⌥⌫")
    }

    func test_withRemoveUnbound_theHintIsGone() {
        setKeymap([:])

        XCTAssertNil(RepoPickerOverlay.footerHints().first { $0.label == "remove worktree" })
    }

    func test_theRemoveHint_showsOnlyOverAWorktreeRow() throws {
        setKeymap([Chord(option: true, key: "⌫"): .removeWorktree])
        let repo = path("alpha")
        let overlay = makeRepoPicker(entries: [workspace("alpha", path: repo)])
        mount(overlay)
        overlay.setWorktrees(listing(repo, "one"), for: repo)

        XCTAssertEqual(shape(of: overlay)[overlay.selected], "workspace:alpha")
        XCTAssertFalse(hintIsShown("remove worktree", in: overlay), "hidden over a workspace")

        send(#selector(NSResponder.moveDown(_:)), to: overlay)

        XCTAssertNotNil(overlay.selectedWorktree)
        XCTAssertTrue(hintIsShown("remove worktree", in: overlay), "shown over a worktree")

        send(#selector(NSResponder.moveUp(_:)), to: overlay)

        XCTAssertFalse(hintIsShown("remove worktree", in: overlay), "and hidden again on the way back")
    }

    func test_theCreateHint_isHiddenOnTheAddRow() {
        setKeymap([Chord(option: true, key: "⏎"): .createWorktree])
        let overlay = makeRepoPicker(entries: [workspace("alpha")])
        mount(overlay)

        XCTAssertTrue(hintIsShown("new worktree", in: overlay), "shown over a workspace")

        send(#selector(NSResponder.moveDown(_:)), to: overlay)

        XCTAssertEqual(shape(of: overlay)[overlay.selected], "add")
        XCTAssertFalse(hintIsShown("new worktree", in: overlay))
    }

    func test_theOpenHint_staysUpOnEveryRow() {
        let repo = path("alpha")
        let overlay = makeRepoPicker(entries: [workspace("alpha", path: repo)])
        mount(overlay)
        overlay.setWorktrees(listing(repo, "one"), for: repo)

        XCTAssertTrue(hintIsShown("open", in: overlay))

        send(#selector(NSResponder.moveDown(_:)), to: overlay)

        XCTAssertTrue(hintIsShown("open", in: overlay))
    }

    func test_overAnOpenWorkspace_theReturnHintSaysSwitch() {
        let open = path("alpha")
        let overlay = makeRepoPicker(
            entries: [workspace("alpha", path: open), workspace("beta", path: path("beta"))],
            openState: { $0 == open ? .here : .closed })
        mount(overlay)

        XCTAssertTrue(hintIsShown("switch", in: overlay), "↵ on an open workspace switches to it")

        send(#selector(NSResponder.moveDown(_:)), to: overlay)

        XCTAssertFalse(hintIsShown("switch", in: overlay), "a closed one opens")
    }

    func test_aWorktreeOpenInItsMirroredSubfolder_isMarkedOpen_withoutThatFolderOnDisk() throws {
        let repo = try GitFixture.makeRepo(at: path("mirror-repo").resolvingSymlinksInPath())
        defer { try? FileManager.default.removeItem(at: repo) }
        let package = repo.appendingPathComponent("pkg", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let tree = worktree(repo, "feat")
        let opened = tree.path.appendingPathComponent("pkg").standardizedFileURL.path
        let overlay = makeRepoPicker(
            entries: [workspace("mono", path: package)],
            openState: { $0.standardizedFileURL.path == opened ? .here : .closed })
        mount(overlay)
        waitUntil(GitRepoStatus.repoRoot(package) != nil, "the repo root to be read off the main thread")

        overlay.setWorktrees(WorktreeListing(commonDir: repo, worktrees: [tree]), for: package)

        let row = try XCTUnwrap(rowViews(in: overlay).compactMap { $0 as? RepoPickerOverlay.RowView }.last)
        XCTAssertNotNil(row.worktree)
        XCTAssertTrue(
            descendants(of: row).contains { ($0 as? NSTextField)?.stringValue == "open" },
            "the open workspace sits at the worktree's copy of pkg, which the picker never reads off disk")
    }

    private func hintIsShown(_ label: String, in overlay: NSView) -> Bool {
        func walk(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(walk) }
        guard
            let field = walk(overlay).compactMap({ $0 as? NSTextField })
                .first(where: { $0.stringValue == label })
        else { return false }
        return !field.isHiddenOrHasHiddenAncestor
    }

    func test_aWorktreeBeingRemoved_rendersAsRemoving() {
        let repo = path("alpha")
        let removals = WorktreeRemovalTracker()
        let overlay = makeRepoPicker(entries: [workspace("alpha", path: repo)], removals: removals)
        mount(overlay)
        removals.begin(worktree(repo, "one").path)

        overlay.setWorktrees(listing(repo, "one", "two"), for: repo)

        XCTAssertEqual(
            shape(of: overlay), ["new", "workspace:alpha", "removing:one", "worktree:two", "add"])
    }

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

    func test_aRemovalStartingUnderAnOpenPicker_swapsTheRowInPlace() {
        let repo = path("alpha")
        let removals = WorktreeRemovalTracker()
        let overlay = makeRepoPicker(entries: [workspace("alpha", path: repo)], removals: removals)
        mount(overlay)
        overlay.setWorktrees(listing(repo, "one", "two"), for: repo)
        XCTAssertEqual(shape(of: overlay), ["new", "workspace:alpha", "worktree:one", "worktree:two", "add"])

        removals.begin(worktree(repo, "one").path)
        overlay.refreshRemovalState()

        XCTAssertEqual(
            shape(of: overlay), ["new", "workspace:alpha", "removing:one", "worktree:two", "add"])
    }

    func test_relisting_dropsAWorktreeGitNoLongerReports() {
        let repo = path("alpha")
        let overlay = makeRepoPicker(entries: [workspace("alpha", path: repo)])
        mount(overlay)
        overlay.setWorktrees(listing(repo, "one", "two"), for: repo)

        overlay.setWorktrees(listing(repo, "two"), for: repo)

        XCTAssertEqual(shape(of: overlay), ["new", "workspace:alpha", "worktree:two", "add"])
    }

    func test_aRemovalFailing_putsTheOrdinaryRowBack() {
        let repo = path("alpha")
        let removals = WorktreeRemovalTracker()
        let overlay = makeRepoPicker(entries: [workspace("alpha", path: repo)], removals: removals)
        mount(overlay)
        removals.begin(worktree(repo, "one").path)
        overlay.setWorktrees(listing(repo, "one", "two"), for: repo)

        removals.finish(worktree(repo, "one").path)
        overlay.refreshRemovalState()

        XCTAssertEqual(shape(of: overlay), ["new", "workspace:alpha", "worktree:one", "worktree:two", "add"])
    }

    func test_aRemovalThatLanded_takesTheRowOutBeforeTheRelist() {
        let repo = path("alpha")
        let removals = WorktreeRemovalTracker()
        let overlay = makeRepoPicker(entries: [workspace("alpha", path: repo)], removals: removals)
        mount(overlay)
        removals.begin(worktree(repo, "one").path)
        overlay.setWorktrees(listing(repo, "one", "two"), for: repo)

        removals.finish(worktree(repo, "one").path)
        overlay.dropWorktree(at: worktree(repo, "one").path)

        XCTAssertEqual(shape(of: overlay), ["new", "workspace:alpha", "worktree:two", "add"])
    }

    private func shape(of overlay: RepoPickerOverlay) -> [String] {
        overlay.rowViews.map { view in
            if let removing = view as? RepoPickerOverlay.RemovingRowView {
                return "removing:\(removing.name)"
            }
            if let action = view as? RepoPickerOverlay.ActionRowView {
                return action.title == "New Workspace" ? "new" : "add"
            }
            guard let row = view as? RepoPickerOverlay.RowView else { return "?" }
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

    private func worktree(_ repo: URL, _ branch: String) -> Worktree {
        Worktree(
            path:
                worktreeRoot
                .appendingPathComponent(repo.lastPathComponent, isDirectory: true)
                .appendingPathComponent(WorktreeStore.slug(forText: branch), isDirectory: true)
                .standardizedFileURL,
            branch: branch, head: "0000000", isLocked: false)
    }

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
        openState: @escaping (URL) -> WorkspaceOpenState = { _ in .closed },
        onChoose: @escaping (Workspace, WorktreeOrigin?) -> Void = { _, _ in }
    ) -> RepoPickerOverlay {
        RepoPickerOverlay(
            entries: entries, background: Theme.current.chrome.background.nsColor,
            removals: removals, openState: openState, onChoose: onChoose, onAddWorkspace: {}, onDismiss: {})
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
