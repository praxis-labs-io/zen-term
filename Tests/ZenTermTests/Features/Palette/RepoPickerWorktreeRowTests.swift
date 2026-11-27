import AppKit
import XCTest

@testable import ZenTerm

final class RepoPickerWorktreeRowTests: WindowTestCase {
    private var window: NSWindow?

    private var worktreeRoot: URL!
    private var repoRoot: URL!

    override func setUp() {
        super.setUp()
        Motion.isReduceMotionEnabled = { true }
        worktreeRoot = tempDirPath().standardizedFileURL
        repoRoot = tempDirPath().standardizedFileURL
        WorktreeStore.rootOverrideForTesting = worktreeRoot
        GitRepoStatus.resetForTesting()
    }

    override func tearDown() {
        window = nil
        WorktreeStore.rootOverrideForTesting = nil
        GitRepoStatus.resetForTesting()
        super.tearDown()
    }

    func test_theList_isOpenHere_thenOtherWindows_thenClosedInConfigOrder_thenAdd() {
        let overlay = makeRepoPicker(
            entries: [
                workspace("gamma", path: path("gamma")), workspace("alpha", path: path("alpha")),
                workspace("beta", path: path("beta")), workspace("delta", path: path("delta")),
            ],
            open: [running(window: 1, name: "alpha", folder: path("alpha"), isWorktree: false)],
            elsewhere: [running(window: 2, name: "beta", folder: path("beta"), isWorktree: false)])
        mount(overlay)

        XCTAssertEqual(
            shape(of: overlay), ["open:alpha", "open:beta", "workspace:gamma", "workspace:delta", "add"],
            "no headings, and closed workspaces keep the config's order rather than the alphabet's")
        XCTAssertFalse(overlay.rowViews.contains { $0 is PaletteSectionHeader })
        XCTAssertEqual(
            overlay.rowViews.compactMap { ($0 as? RepoPickerOverlay.RowView)?.state },
            [.open, .otherWindow], "open rows say where they are open, closed ones say nothing")
    }

    func test_aClosedParentOpenInAnotherWindow_isALabel_notASecondCopy() {
        let repo = path("alpha")
        let tree = worktree(repo, "one")
        let overlay = makeRepoPicker(
            entries: [workspace("alpha", path: repo)],
            open: [running(window: 1, name: "alpha", folder: repo, isWorktree: false)],
            elsewhere: [
                RunningWorkspace(
                    window: 2, id: nil, name: "alpha", folder: repo, isWorktree: false, removedWorktreeName: nil),
                running(window: 2, name: "alpha: one", folder: tree.path),
            ])
        mount(overlay)

        XCTAssertEqual(shape(of: overlay), ["open:alpha", "ghost:alpha", "open:alpha: one", "add"])
        XCTAssertFalse(overlay.isSelectable(at: 1), "alpha is already listed open, so its label is not a stop")
    }

    func test_withOnlyTheCurrentWorkspaceOpen_theSelectionStartsOnAClosedOne() {
        let overlay = makeRepoPicker(
            entries: [workspace("alpha", path: path("alpha")), workspace("beta", path: path("beta"))],
            open: [running(window: 1, name: "alpha", folder: path("alpha"), isWorktree: false)],
            current: WorkspaceID(raw: 1))
        mount(overlay)

        XCTAssertEqual(shape(of: overlay)[overlay.selected], "workspace:beta", "not the one already showing")
    }

    func test_aClosedParent_isFoundByTheTitleItShows_afterAConfigRename() {
        let repo = path("alpha")
        let tree = worktree(repo, "one")
        let overlay = makeRepoPicker(
            entries: [workspace("Renamed", path: repo)],
            open: [
                RunningWorkspace(
                    window: 1, id: nil, name: "alpha", folder: repo, isWorktree: false, removedWorktreeName: nil),
                running(window: 1, name: "alpha: one", folder: tree.path),
            ])
        mount(overlay)

        type("Renamed", into: overlay)

        XCTAssertEqual(shape(of: overlay), ["new", "workspace:Renamed", "open:alpha: one", "add"])
    }

    func test_theCreateHint_readsTheChordFromTheLiveKeymap() {
        setKeymap([Chord(command: true, shift: true, key: "n"): .createWorktree])
        let overlay = makeRepoPicker(entries: [workspace("alpha")])
        mount(overlay)

        let hint = overlay.barHintsForTesting.first { $0.label == "New Worktree" }
        XCTAssertEqual(hint?.keys, "⌘⇧N")
    }

    func test_withTheActionUnbound_theHintIsGone() {
        setKeymap([:])
        let overlay = makeRepoPicker(entries: [workspace("alpha")])
        mount(overlay)

        XCTAssertEqual(overlay.barHintsForTesting.map(\.label), ["Open"])
    }

    func test_theCreateTarget_isNilOnTheActionRows() {
        let overlay = makeRepoPicker(entries: [workspace("alpha")])
        mount(overlay)

        XCTAssertEqual(shape(of: overlay)[overlay.selected], "workspace:alpha")
        XCTAssertNotNil(overlay.createTarget)

        send(#selector(NSResponder.moveDown(_:)), to: overlay)

        XCTAssertEqual(shape(of: overlay)[overlay.selected], "add")
        XCTAssertNil(overlay.createTarget)

        type("zz", into: overlay)

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
            ["workspace:alpha", "worktree:one", "worktree:two", "workspace:beta", "add"])
    }

    func test_worktreeRow_readsAsAWorktreeOnTheLeftAndItsBranchOnTheRight() throws {
        let repo = path("alpha")
        let overlay = makeRepoPicker(entries: [workspace("alpha", path: repo)])
        mount(overlay)

        overlay.setWorktrees(listing(repo, "feature/zen-455"), for: repo)

        let row = try XCTUnwrap(rowViews(in: overlay)[1] as? RepoPickerOverlay.RowView)
        XCTAssertNotNil(label(in: row, saying: RepoPickerOverlay.RowView.typeRail))
        XCTAssertEqual(rightColumn(of: row), "feature/zen-455")
    }

    func test_everyRow_leadsWithALucideChip_mutedUntilItIsOpen() throws {
        let repo = path("alpha")
        let overlay = makeRepoPicker(entries: [workspace("alpha", path: repo)])
        mount(overlay)
        overlay.setWorktrees(listing(repo, "one"), for: repo)
        type("alp", into: overlay)
        overlay.layoutSubtreeIfNeeded()

        let rows = overlay.rowViews.compactMap { $0 as? ListRow }
        XCTAssertEqual(
            rows.map(\.content.leading),
            [
                .process(.newWorkspace), .process(.closedWorkspace), .process(.closedWorktree),
                .process(.addWorkspace),
            ], "an action leads in the Workspaces tint, and a row nothing has opened leads muted")
        for row in rows {
            let badge = try XCTUnwrap(row.processBadgeForTesting, "\(row.title) leads with no chip")
            XCTAssertNotNil(badge.process?.image, "\(row.title)'s Lucide mark is not in the bundle")
        }
    }

    func test_aRowsChip_isInTheWorkspacesTintOnlyWhileOpen() {
        typealias Style = RepoPickerOverlay.RowView.Style
        XCTAssertEqual(Style.workspace.icon(isOpen: true), .workspace)
        XCTAssertEqual(Style.workspace.icon(isOpen: false), .closedWorkspace)
        XCTAssertEqual(Style.openChild.icon(isOpen: true), .workspaceWorktree)
        XCTAssertEqual(Style.closedChild.icon(isOpen: false), .closedWorktree)
        XCTAssertEqual(Style.ghost.icon(isOpen: false), .closedWorkspace)
    }

    func test_theState_followsTheLabel_whileTheBranchStaysTrailing() throws {
        let repo = path("alpha")
        let tree = worktree(repo, "one")
        let overlay = makeRepoPicker(
            entries: [workspace("alpha", path: repo)], openState: { $0 == tree.path ? .here : .closed })
        mount(overlay)
        overlay.setWorktrees(listing(repo, "one"), for: repo)
        overlay.layoutSubtreeIfNeeded()

        let row = try XCTUnwrap(rowViews(in: overlay)[1] as? RepoPickerOverlay.RowView)
        XCTAssertEqual(row.state, .open)
        let title = try XCTUnwrap(label(in: row, saying: RepoPickerOverlay.RowView.typeRail))
        let state = try XCTUnwrap(label(in: row, saying: "Open"))
        let branch = try XCTUnwrap(label(in: row, saying: "one"))
        let titleFrame = title.convert(title.bounds, to: row)
        let stateFrame = state.convert(state.bounds, to: row)
        let branchFrame = branch.convert(branch.bounds, to: row)
        XCTAssertGreaterThanOrEqual(stateFrame.minX, titleFrame.maxX, "the state follows the label")
        XCTAssertLessThanOrEqual(stateFrame.minX - titleFrame.maxX, ChromeMetrics.Spacing.s6, "and sits just after it")
        XCTAssertEqual(state.textColor, Theme.current.chrome.ink(.muted))
        XCTAssertGreaterThan(
            branchFrame.minX, stateFrame.maxX + ChromeMetrics.Spacing.s16, "the branch is not beside it")
        XCTAssertEqual(
            branchFrame.maxX, row.bounds.maxX - ChromeMetrics.Spacing.controlInset, accuracy: ChromeMetrics.Spacing.s4,
            "the branch stays at the trailing edge")
    }

    func test_branchSitsInTheSameColumnOnAWorkspaceAndAWorktree() throws {
        let repo = path("alpha")
        GitRepoStatus.resetForTesting()
        let overlay = makeRepoPicker(entries: [workspace("alpha", path: repo)])
        mount(overlay)
        overlay.setWorktrees(listing(repo, "one"), for: repo)

        let parent = try XCTUnwrap(rowViews(in: overlay)[0] as? RepoPickerOverlay.RowView)
        let child = try XCTUnwrap(rowViews(in: overlay)[1] as? RepoPickerOverlay.RowView)
        overlay.layoutSubtreeIfNeeded()
        let parentBranch = try XCTUnwrap(branchLabel(in: parent))
        let childBranch = try XCTUnwrap(branchLabel(in: child))
        XCTAssertEqual(
            parentBranch.convert(parentBranch.bounds, to: overlay).maxX,
            childBranch.convert(childBranch.bounds, to: overlay).maxX,
            accuracy: 0.5, "both branches end at the same trailing edge")
    }

    func test_aClosedWorktreesTypeRail_isMutedAndSmallerThanAWorkspaceName() throws {
        let repo = path("alpha")
        let overlay = makeRepoPicker(entries: [workspace("alpha", path: repo)])
        mount(overlay)

        overlay.setWorktrees(listing(repo, "one"), for: repo)

        let parent = try XCTUnwrap(rowViews(in: overlay)[0] as? RepoPickerOverlay.RowView)
        let child = try XCTUnwrap(rowViews(in: overlay)[1] as? RepoPickerOverlay.RowView)
        let name = try XCTUnwrap(label(in: parent, saying: "alpha"))
        let rail = try XCTUnwrap(label(in: child, saying: RepoPickerOverlay.RowView.typeRail))
        XCTAssertEqual(name.textColor, Theme.current.chrome.ink(.normal))
        XCTAssertEqual(rail.textColor, Theme.current.chrome.ink(.muted))
        XCTAssertEqual(name.font?.pointSize, ChromeType.Role.body.pointSize)
        XCTAssertLessThan(try XCTUnwrap(rail.font?.pointSize), ChromeType.Role.body.pointSize)
    }

    func test_aWorktreeRow_announcesItsBranch_notJustItsTypeRail() throws {
        let repo = path("alpha")
        let overlay = makeRepoPicker(entries: [workspace("alpha", path: repo)])
        mount(overlay)

        overlay.setWorktrees(listing(repo, "one"), for: repo)

        let child = try XCTUnwrap(rowViews(in: overlay)[1] as? RepoPickerOverlay.RowView)
        XCTAssertEqual(child.accessibilityLabel(), RepoPickerOverlay.RowView.typeRail)
        XCTAssertEqual(child.accessibilityValue() as? String, "worktree on branch one")
    }

    func test_detachedWorktree_showsItsShortHeadInTheBranchColumn() throws {
        let repo = path("alpha")
        let overlay = makeRepoPicker(entries: [workspace("alpha", path: repo)])
        mount(overlay)

        let detached = Worktree(
            path: worktreeRoot.appendingPathComponent("alpha/loose", isDirectory: true), branch: nil,
            head: "abc1234def5678901234567890abcdef12345678", isLocked: false)
        overlay.setWorktrees(WorktreeListing(commonDir: repo, worktrees: [detached]), for: repo)

        let row = try XCTUnwrap(rowViews(in: overlay)[1] as? RepoPickerOverlay.RowView)
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

        overlay.activate(index: 1, modifiers: [])

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
        let before = rowViews(in: overlay)[1]

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
            title: "alpha", path: repo, tabs: [Workspace.Tab(main: "nvim", right: "claude", bottom: "shell")],
            focus: Workspace.LaunchFocus(tab: 0, region: .right), env: ["A": "1"], carry: [".env"])
        let overlay = makeRepoPicker(entries: [parent], onChoose: { ws, _ in chosen = ws })
        mount(overlay)
        overlay.setWorktrees(listing(repo, "feature"), for: repo)

        overlay.activate(index: 1, modifiers: [])

        XCTAssertEqual(chosen?.title, "alpha: feature")
        XCTAssertEqual(chosen?.path.lastPathComponent, "feature")
        XCTAssertEqual(chosen?.tabs[0].main, "nvim")
        XCTAssertEqual(chosen?.tabs[0].right, "claude")
        XCTAssertEqual(chosen?.tabs[0].bottom, "shell")
        XCTAssertEqual(chosen?.focus, Workspace.LaunchFocus(tab: 0, region: .right))
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
            shape(of: overlay),
            ["workspace:alpha", "worktree:one", "workspace:alpha wt", "add"])
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
            ["workspace:alpha", "worktree:one", "workspace:beta", "worktree:two", "add"])
    }

    func test_aWorktreeThatIsAlreadyAWorkspace_isNotRepeated() {
        let repo = path("alpha")
        let tree = worktree(repo, "one")
        let overlay = makeRepoPicker(
            entries: [workspace("alpha", path: repo), workspace("one", path: tree.path)])
        mount(overlay)

        overlay.setWorktrees(WorktreeListing(commonDir: repo, worktrees: [tree]), for: repo)

        XCTAssertEqual(shape(of: overlay), ["workspace:alpha", "workspace:one", "add"])
    }

    func test_churnLabel_isCappedToOneLine() throws {
        let repo = path("alpha")
        let overlay = makeRepoPicker(entries: [workspace("alpha", path: repo)])
        mount(overlay)

        let row = try XCTUnwrap(rowViews(in: overlay)[0] as? RepoPickerOverlay.RowView)
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
            shape(of: overlay), ["workspace:Docs", "workspace:Repo", "worktree:one", "add"])
    }

    func test_ownership_doesNotMoveWhenAFilterReordersTheList() throws {
        let owner = path("owner")
        let other = path("other")
        let shared = owner.appendingPathComponent(".git")
        var chosen: Workspace?
        let ownerWorkspace = Workspace(
            title: "b-x", path: owner, tabs: [Workspace.Tab(main: "nvim")], env: [:])
        let overlay = makeRepoPicker(
            entries: [ownerWorkspace, workspace("a-x", path: other)],
            onChoose: { ws, _ in chosen = ws })
        mount(overlay)
        let trees = [worktree(owner, "shared-branch")]
        overlay.setWorktrees(WorktreeListing(commonDir: shared, worktrees: trees), for: owner)
        overlay.setWorktrees(WorktreeListing(commonDir: shared, worktrees: trees), for: other)
        XCTAssertEqual(
            shape(of: overlay),
            ["workspace:b-x", "worktree:shared-branch", "workspace:a-x", "add"])

        type("x", into: overlay)

        XCTAssertEqual(
            shape(of: overlay),
            ["new", "workspace:a-x", "workspace:b-x", "worktree:shared-branch", "add"],
            "the filter reorders the workspaces, and the worktree stays with b-x")
        let index = try XCTUnwrap(shape(of: overlay).firstIndex(of: "worktree:shared-branch"))
        overlay.activate(index: index, modifiers: [])
        XCTAssertEqual(chosen?.tabs[0].main, "nvim", "b-x's recipe, not a-x's")
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
        XCTAssertEqual(overlay.selected, 1, "standing on beta")

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
        let repo = path("alpha")
        let overlay = makeRepoPicker(entries: [workspace("alpha", path: repo)])
        mount(overlay)
        overlay.setWorktrees(listing(repo, "one"), for: repo)
        send(#selector(NSResponder.moveDown(_:)), to: overlay)

        let hint = overlay.barHintsForTesting.first { $0.label == "Remove Worktree" }
        XCTAssertEqual(hint?.keys, "⌥⌫")
    }

    func test_withRemoveUnbound_theHintIsGone() {
        setKeymap([:])
        let repo = path("alpha")
        let overlay = makeRepoPicker(entries: [workspace("alpha", path: repo)])
        mount(overlay)
        overlay.setWorktrees(listing(repo, "one"), for: repo)
        send(#selector(NSResponder.moveDown(_:)), to: overlay)

        XCTAssertNotNil(overlay.selectedWorktree, "premise: a worktree is selected")
        XCTAssertNil(overlay.barHintsForTesting.first { $0.label == "Remove Worktree" })
    }

    func test_theRemoveHint_showsOnlyOverAWorktreeRow() throws {
        setKeymap([Chord(option: true, key: "⌫"): .removeWorktree])
        let repo = path("alpha")
        let overlay = makeRepoPicker(entries: [workspace("alpha", path: repo)])
        mount(overlay)
        overlay.setWorktrees(listing(repo, "one"), for: repo)

        XCTAssertEqual(shape(of: overlay)[overlay.selected], "workspace:alpha")
        XCTAssertFalse(hintIsShown("Remove Worktree", in: overlay), "hidden over a workspace")

        send(#selector(NSResponder.moveDown(_:)), to: overlay)

        XCTAssertNotNil(overlay.selectedWorktree)
        XCTAssertTrue(hintIsShown("Remove Worktree", in: overlay), "shown over a worktree")

        send(#selector(NSResponder.moveUp(_:)), to: overlay)

        XCTAssertFalse(hintIsShown("Remove Worktree", in: overlay), "and hidden again on the way back")
    }

    func test_theCreateHint_isHiddenOnTheAddRow() {
        setKeymap([Chord(option: true, key: "⏎"): .createWorktree])
        let overlay = makeRepoPicker(entries: [workspace("alpha")])
        mount(overlay)

        XCTAssertTrue(hintIsShown("New Worktree", in: overlay), "shown over a workspace")

        send(#selector(NSResponder.moveDown(_:)), to: overlay)

        XCTAssertEqual(shape(of: overlay)[overlay.selected], "add")
        XCTAssertFalse(hintIsShown("New Worktree", in: overlay))
        XCTAssertTrue(hintIsShown("Add Workspace", in: overlay), "Return on the add row adds, it opens nothing")
        XCTAssertFalse(hintIsShown("Open", in: overlay))
    }

    func test_theReturnHint_namesWhatTheSelectedRowDoes() {
        let repo = path("alpha")
        let overlay = makeRepoPicker(entries: [workspace("alpha", path: repo)])
        mount(overlay)
        overlay.setWorktrees(listing(repo, "one"), for: repo)

        XCTAssertTrue(hintIsShown("Open", in: overlay))
        XCTAssertFalse(hintIsShown("New Workspace", in: overlay), "an empty query lists no New Workspace row")

        send(#selector(NSResponder.moveDown(_:)), to: overlay)

        XCTAssertTrue(hintIsShown("Open", in: overlay), "and on the worktree under it")

        type("zz", into: overlay)

        XCTAssertTrue(hintIsShown("New Workspace", in: overlay), "↵ makes one when the query matches nothing")
        XCTAssertFalse(hintIsShown("Open", in: overlay), "it opens nothing")
    }

    func test_overAnOpenWorkspace_theReturnHintSaysSwitch() {
        let open = path("alpha")
        let overlay = makeRepoPicker(
            entries: [workspace("alpha", path: open), workspace("beta", path: path("beta"))],
            openState: { $0 == open ? .here : .closed })
        mount(overlay)

        XCTAssertTrue(hintIsShown("Switch", in: overlay), "↵ on an open workspace switches to it")

        send(#selector(NSResponder.moveDown(_:)), to: overlay)

        XCTAssertFalse(hintIsShown("Switch", in: overlay), "a closed one opens")
    }

    func test_aWorktreeOpenInItsMirroredSubfolder_leavesConfigured_withoutThatFolderOnDisk() throws {
        let repo = try GitFixture.makeRepo(at: path("mirror-repo").resolvingSymlinksInPath())
        defer { try? FileManager.default.removeItem(at: repo) }
        let package = repo.appendingPathComponent("pkg", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let tree = worktree(repo, "feat")
        let opened = tree.path.appendingPathComponent("pkg").standardizedFileURL
        let overlay = makeRepoPicker(
            entries: [workspace("mono", path: package)],
            open: [running(window: 1, name: "mono: feat", folder: opened)])
        mount(overlay)
        waitUntil(GitRepoStatus.repoRoot(package) != nil, "the repo root to be read off the main thread")

        overlay.setWorktrees(WorktreeListing(commonDir: repo, worktrees: [tree]), for: package)

        XCTAssertFalse(
            shape(of: overlay).contains("worktree:feat"),
            "the open workspace sits at the worktree's copy of pkg, which the picker never reads off disk")
        XCTAssertTrue(shape(of: overlay).contains("open:mono: feat"), "it is listed as open instead")
    }

    func test_aWorktreeOpenHere_andInAnotherWindowAtItsRoot_isListedUnderOpen() throws {
        let repo = try GitFixture.makeRepo(at: path("both-repo").resolvingSymlinksInPath())
        defer { try? FileManager.default.removeItem(at: repo) }
        let package = repo.appendingPathComponent("pkg", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let tree = worktree(repo, "feat")
        let mirror = tree.path.appendingPathComponent("pkg").standardizedFileURL
        let root = tree.path.standardizedFileURL
        let overlay = makeRepoPicker(
            entries: [workspace("mono", path: package)],
            open: [running(window: 1, name: "mono: feat", folder: mirror)],
            elsewhere: [running(window: 2, name: "mono: feat", folder: root)])
        mount(overlay)
        waitUntil(GitRepoStatus.repoRoot(package) != nil, "the repo root to be read off the main thread")

        overlay.setWorktrees(WorktreeListing(commonDir: repo, worktrees: [tree]), for: package)

        let here = try XCTUnwrap(
            rowViews(in: overlay).firstIndex {
                ($0 as? RepoPickerOverlay.RowView)?.running?.window == 1
            })
        XCTAssertEqual(state(at: here, in: overlay), .open, "this window holds it, so it is switched to")
        XCTAssertFalse(
            shape(of: overlay).contains("worktree:feat"),
            "and it never doubles as a configured row under its parent")
    }

    private func hintIsShown(_ label: String, in overlay: NSView) -> Bool {
        func walk(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(walk) }
        guard let bar = walk(overlay).compactMap({ $0 as? HintFooter }).first else { return false }
        return walk(bar).compactMap { $0 as? NSTextField }.contains {
            $0.stringValue == label && !$0.isHiddenOrHasHiddenAncestor
        }
    }

    func test_aWorktreeBeingRemoved_rendersAsRemoving() {
        let repo = path("alpha")
        let removals = WorktreeRemovalTracker()
        let overlay = makeRepoPicker(entries: [workspace("alpha", path: repo)], removals: removals)
        mount(overlay)
        removals.begin(worktree(repo, "one").path)

        overlay.setWorktrees(listing(repo, "one", "two"), for: repo)

        XCTAssertEqual(
            shape(of: overlay), ["workspace:alpha", "removing:one", "worktree:two", "add"])
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
        XCTAssertEqual(
            shape(of: overlay), ["workspace:alpha", "worktree:one", "worktree:two", "add"])

        removals.begin(worktree(repo, "one").path)
        overlay.refreshRemovalState()

        XCTAssertEqual(
            shape(of: overlay), ["workspace:alpha", "removing:one", "worktree:two", "add"])
    }

    func test_relisting_dropsAWorktreeGitNoLongerReports() {
        let repo = path("alpha")
        let overlay = makeRepoPicker(entries: [workspace("alpha", path: repo)])
        mount(overlay)
        overlay.setWorktrees(listing(repo, "one", "two"), for: repo)

        overlay.setWorktrees(listing(repo, "two"), for: repo)

        XCTAssertEqual(shape(of: overlay), ["workspace:alpha", "worktree:two", "add"])
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

        XCTAssertEqual(
            shape(of: overlay), ["workspace:alpha", "worktree:one", "worktree:two", "add"])
    }

    func test_aRemovalThatLanded_takesTheRowOutBeforeTheRelist() {
        let repo = path("alpha")
        let removals = WorktreeRemovalTracker()
        let overlay = makeRepoPicker(entries: [workspace("alpha", path: repo)], removals: removals)
        mount(overlay)
        removals.begin(worktree(repo, "one").path)
        overlay.setWorktrees(listing(repo, "one", "two"), for: repo)

        removals.finish(worktree(repo, "one").path)
        overlay.dropWorktree(at: worktree(repo, "one").path, open: [])

        XCTAssertEqual(shape(of: overlay), ["workspace:alpha", "worktree:two", "add"])
    }

    func test_aRemovalStartingOnTheSelectedRow_landsOnTheNextRowNotTheTop() {
        let repo = path("alpha")
        let removals = WorktreeRemovalTracker()
        let overlay = makeRepoPicker(entries: [workspace("alpha", path: repo)], removals: removals)
        mount(overlay)
        overlay.setWorktrees(listing(repo, "one", "two"), for: repo)
        send(#selector(NSResponder.moveDown(_:)), to: overlay)
        XCTAssertEqual(shape(of: overlay)[overlay.selected], "worktree:one")

        removals.begin(worktree(repo, "one").path)
        overlay.refreshRemovalState()

        XCTAssertEqual(shape(of: overlay)[overlay.selected], "worktree:two")

        removals.finish(worktree(repo, "one").path)
        overlay.dropWorktree(at: worktree(repo, "one").path, open: [])

        XCTAssertEqual(shape(of: overlay)[overlay.selected], "worktree:two")
    }

    func test_aSelectedRowThatDisappears_landsOnTheRowThatTookItsPlace() {
        let repo = path("alpha")
        let overlay = makeRepoPicker(entries: [workspace("alpha", path: repo)])
        mount(overlay)
        overlay.setWorktrees(listing(repo, "one", "two"), for: repo)
        send(#selector(NSResponder.moveDown(_:)), to: overlay)

        overlay.setWorktrees(listing(repo, "two"), for: repo)

        XCTAssertEqual(shape(of: overlay)[overlay.selected], "worktree:two")
    }

    func test_anOpenWorktreeRemovedOutsideZenTerm_saysSoAndStillSwitches() throws {
        let repo = path("alpha")
        let tree = worktree(repo, "one")
        var switched: WorkspaceID?
        let overlay = makeRepoPicker(
            entries: [workspace("alpha", path: repo)],
            open: [
                running(window: 1, name: "alpha", folder: repo, isWorktree: false),
                running(window: 1, name: "alpha: one", folder: tree.path, removedWorktreeName: "one"),
            ],
            onSwitch: { switched = $0 })
        mount(overlay)
        overlay.setWorktrees(listing(repo, "one"), for: repo)
        send(#selector(NSResponder.moveDown(_:)), to: overlay)

        XCTAssertEqual(shape(of: overlay)[overlay.selected], "open:alpha: one")
        XCTAssertEqual(rightColumn(of: overlay.rowViews[overlay.selected]), "one removed")
        XCTAssertNil(overlay.selectedWorktree, "a listing that still has it does not make ⌘⇧⌫ remove it again")
        XCTAssertEqual(overlay.selectedRemovedWorkspace?.name, "alpha: one", "⌘⇧⌫ closes it instead")

        send(#selector(NSResponder.insertNewline(_:)), to: overlay)

        XCTAssertEqual(switched, WorkspaceID(raw: 1))
    }

    func test_anOpenWorktreeBeingRemoved_rendersAsRemoving() {
        let repo = path("alpha")
        let tree = worktree(repo, "one")
        let removals = WorktreeRemovalTracker()
        let overlay = makeRepoPicker(
            entries: [workspace("alpha", path: repo)],
            open: [
                running(window: 1, name: "alpha", folder: repo, isWorktree: false),
                running(window: 1, name: "alpha: one", folder: tree.path),
            ],
            removals: removals)
        mount(overlay)
        overlay.setWorktrees(listing(repo, "one"), for: repo)
        send(#selector(NSResponder.moveDown(_:)), to: overlay)
        XCTAssertEqual(shape(of: overlay)[overlay.selected], "open:alpha: one")

        removals.begin(tree.path)
        overlay.refreshRemovalState()

        XCTAssertEqual(
            shape(of: overlay),
            ["open:alpha", "removing:one", "add"])
        XCTAssertFalse(overlay.isSelectable(at: 1), "a row being removed takes no chord")
        XCTAssertEqual(shape(of: overlay)[overlay.selected], "add", "the next row down, not the top")
    }

    func test_anOpenWorktreeRemoved_leavesItsOpenGroupWithThePickerUp() {
        let repo = path("alpha")
        let tree = worktree(repo, "one")
        let parent = running(window: 1, name: "alpha", folder: repo, isWorktree: false)
        let removals = WorktreeRemovalTracker()
        let overlay = makeRepoPicker(
            entries: [workspace("alpha", path: repo)],
            open: [parent, running(window: 1, name: "alpha: one", folder: tree.path)],
            removals: removals)
        mount(overlay)
        overlay.setWorktrees(listing(repo, "one"), for: repo)
        removals.begin(tree.path)
        overlay.refreshRemovalState()

        removals.finish(tree.path)
        overlay.dropWorktree(at: tree.path, open: [parent])

        XCTAssertEqual(shape(of: overlay), ["open:alpha", "add"])
    }

    func test_aWorktreeRemovedElsewhere_takesItsRow_andItsClosedParentMovesToTheClosedWorkspaces() {
        let repo = path("alpha")
        let tree = worktree(repo, "one")
        let removals = WorktreeRemovalTracker()
        let overlay = makeRepoPicker(
            entries: [workspace("alpha", path: repo)],
            elsewhere: [
                RunningWorkspace(
                    window: 2, id: nil, name: "alpha", folder: repo, isWorktree: false, removedWorktreeName: nil),
                running(window: 2, name: "alpha: one", folder: tree.path),
            ],
            removals: removals)
        mount(overlay)
        overlay.setWorktrees(listing(repo, "one"), for: repo)
        XCTAssertEqual(
            shape(of: overlay),
            ["workspace:alpha", "open:alpha: one", "add"],
            "the closed parent leads its open worktree's group, and is not repeated below")

        overlay.dropWorktree(at: tree.path, open: [])

        XCTAssertEqual(shape(of: overlay), ["workspace:alpha", "add"])
    }

    private func shape(of overlay: RepoPickerOverlay) -> [String] {
        overlay.rowViews.map { view in
            if let removing = view as? RepoPickerOverlay.RemovingRowView {
                return "removing:\(removing.name)"
            }
            if let action = view as? RepoPickerOverlay.ActionRowView {
                return action.title.hasPrefix("New Workspace") ? "new" : "add"
            }
            guard let row = view as? RepoPickerOverlay.RowView else { return "?" }
            if let worktree = row.worktree {
                return "worktree:\(worktree.name)"
            }
            if let workspace = row.workspace {
                return "workspace:" + workspace.title
            }
            if let running = row.running {
                return (running.id == nil ? "ghost:" : "open:") + running.name
            }
            return "?"
        }
    }

    func test_withNothingConfigured_theListIsTheAddRow() {
        let overlay = makeRepoPicker(entries: [])
        mount(overlay)

        XCTAssertEqual(
            shape(of: overlay), ["add"], "the first run a new user sees: Add Workspace… and nothing else")
    }

    func test_anOpenWorktreeRow_stillAnswersBothWorktreeChords() throws {
        let repo = path("alpha")
        let tree = worktree(repo, "one")
        let overlay = makeRepoPicker(
            entries: [workspace("alpha", path: repo)],
            open: [
                running(window: 1, name: "alpha", folder: repo, isWorktree: false),
                running(window: 1, name: "alpha: one", folder: tree.path),
            ])
        mount(overlay)
        overlay.setWorktrees(listing(repo, "one"), for: repo)
        send(#selector(NSResponder.moveDown(_:)), to: overlay)

        XCTAssertEqual(shape(of: overlay)[overlay.selected], "open:alpha: one")
        let target = try XCTUnwrap(overlay.createTarget, "⌥⏎ still makes a worktree from it")
        XCTAssertEqual(target.workspace.title, "alpha", "carry comes from the configured parent")
        XCTAssertEqual(target.repo, tree.path)
        let selected = try XCTUnwrap(overlay.selectedWorktree, "⌘⇧⌫ still removes it")
        XCTAssertEqual(selected.worktree.branch, "one")
        XCTAssertEqual(selected.parent.title, "alpha")
    }

    func test_aQueryMatchingOnlyAnOpenWorkspacesWorktree_keepsItUnderItsOpenParent() {
        let repo = path("alpha")
        let overlay = makeRepoPicker(
            entries: [workspace("alpha", path: repo)],
            open: [running(window: 1, name: "alpha", folder: repo, isWorktree: false)])
        mount(overlay)
        overlay.setWorktrees(listing(repo, "one"), for: repo)

        type("one", into: overlay)

        XCTAssertEqual(
            shape(of: overlay), ["new", "open:alpha", "worktree:one", "add"],
            "a worktree row never renders orphaned, and alpha is never redrawn as closed")
    }

    func test_aQueryOnlyAWorktreeMatched_preselectsThatWorktree() {
        let repo = path("alpha")
        let overlay = makeRepoPicker(
            entries: [workspace("alpha", path: repo)],
            open: [running(window: 1, name: "alpha", folder: repo, isWorktree: false)])
        mount(overlay)
        overlay.setWorktrees(listing(repo, "one"), for: repo)

        type("one", into: overlay)

        XCTAssertEqual(
            shape(of: overlay)[overlay.selected], "worktree:one",
            "the parent did not match, so ↵ must not land on it")
    }

    func test_aRevealThatFindsNoWindow_opensTheConfiguredWorkspaceInstead() {
        var chosen: Workspace?
        let repo = path("alpha")
        let overlay = makeRepoPicker(
            entries: [workspace("alpha", path: repo)],
            elsewhere: [running(window: 2, name: "alpha", folder: repo, isWorktree: false)],
            onChoose: { ws, _ in chosen = ws }, onReveal: { _, _ in false })
        mount(overlay)

        send(#selector(NSResponder.insertNewline(_:)), to: overlay)

        XCTAssertEqual(
            chosen?.title, "alpha",
            "the window holding it closed, so ⌘P keeps its promise and opens the entry")
    }

    func test_aRevealThatFindsNoWindow_andNoEntry_dropsTheRowAndStays() {
        var chosen: Workspace?
        let overlay = makeRepoPicker(
            entries: [workspace("alpha", path: path("alpha"))],
            elsewhere: [running(window: 2, name: "Workspace 1", folder: path("home"), isWorktree: false)],
            onChoose: { ws, _ in chosen = ws }, onReveal: { _, _ in false })
        mount(overlay)

        send(#selector(NSResponder.insertNewline(_:)), to: overlay)

        XCTAssertNil(chosen, "an unconfigured workspace has no entry to fall back to")
        XCTAssertFalse(
            shape(of: overlay).contains("open:Workspace 1"), "the stale row goes in front of the person")
    }

    func test_newWorkspace_readsAsARow_whileAddWorkspaceStaysQuiet() throws {
        let overlay = makeRepoPicker(entries: [workspace("alpha")])
        mount(overlay)
        type("alp", into: overlay)

        let actions = rowViews(in: overlay).compactMap { $0 as? RepoPickerOverlay.ActionRowView }
        let new = try XCTUnwrap(actions.first { $0.title == "New Workspace “alp”" })
        let add = try XCTUnwrap(actions.first { $0.title == "Add Workspace…" })
        let workspaceRow = try XCTUnwrap(
            rowViews(in: overlay).compactMap { $0 as? RepoPickerOverlay.RowView }.first)

        let newLabel = try XCTUnwrap(label(in: new, saying: "New Workspace “alp”"))
        let addLabel = try XCTUnwrap(label(in: add, saying: "Add Workspace…"))
        let name = try XCTUnwrap(label(in: workspaceRow, saying: "alpha"))

        XCTAssertEqual(newLabel.textColor, name.textColor, "it holds the default selection")
        XCTAssertEqual(newLabel.font, name.font)
        XCTAssertEqual(
            addLabel.textColor, Theme.current.chrome.ink(.muted), "the trailing action stays quiet")
    }

    func test_anOpenWorkspacesUnopenedWorktree_joinsItsOpenGroup() {
        let repo = path("alpha")
        let overlay = makeRepoPicker(
            entries: [workspace("alpha", path: repo)],
            open: [running(window: 1, name: "alpha", folder: repo, isWorktree: false)])
        mount(overlay)

        overlay.setWorktrees(listing(repo, "one"), for: repo)

        XCTAssertEqual(
            shape(of: overlay),
            ["open:alpha", "worktree:one", "add"], "a worktree sits under its parent, open or not")
    }

    func test_theClosedParentOfAnOpenWorktree_isAStop_andReturnOpensIt() {
        let repo = path("alpha")
        let tree = worktree(repo, "one")
        var chosen: [Workspace] = []
        let overlay = makeRepoPicker(
            entries: [workspace("alpha", path: repo)],
            open: [
                RunningWorkspace(
                    window: 1, id: nil, name: "alpha", folder: repo, isWorktree: false, removedWorktreeName: nil),
                running(window: 1, name: "alpha: one", folder: tree.path),
            ],
            onChoose: { ws, _ in chosen.append(ws) })
        mount(overlay)
        overlay.setWorktrees(listing(repo, "one"), for: repo)
        XCTAssertEqual(shape(of: overlay), ["workspace:alpha", "open:alpha: one", "add"])
        XCTAssertEqual(shape(of: overlay)[overlay.selected], "open:alpha: one", "the first open row")

        send(#selector(NSResponder.moveUp(_:)), to: overlay)

        XCTAssertEqual(shape(of: overlay)[overlay.selected], "workspace:alpha", "the closed parent is a stop")
        XCTAssertTrue(hintIsShown("Open", in: overlay))
        send(#selector(NSResponder.insertNewline(_:)), to: overlay)
        XCTAssertEqual(chosen.map(\.title), ["alpha"])
    }

    func test_returnOnAnOpenWorkspacesUnopenedWorktree_opensIt() {
        let repo = path("alpha")
        var chosen: Workspace?
        let overlay = makeRepoPicker(
            entries: [workspace("alpha", path: repo)],
            open: [running(window: 1, name: "alpha", folder: repo, isWorktree: false)],
            onChoose: { ws, _ in chosen = ws })
        mount(overlay)
        overlay.setWorktrees(listing(repo, "one"), for: repo)
        send(#selector(NSResponder.moveDown(_:)), to: overlay)

        send(#selector(NSResponder.insertNewline(_:)), to: overlay)

        XCTAssertEqual(chosen?.title, "alpha: one", "reachable from ⌘P while its parent is open")
    }

    private func rowViews(in overlay: RepoPickerOverlay) -> [PaletteRowView] { overlay.rowViews }

    private func state(at index: Int, in overlay: RepoPickerOverlay) -> RepoPickerOverlay.State? {
        (overlay.rowViews[index] as? RepoPickerOverlay.RowView)?.state
    }

    private func running(
        window: Int, name: String, folder: URL, isWorktree: Bool = true, removedWorktreeName: String? = nil
    ) -> RunningWorkspace {
        RunningWorkspace(
            window: window, id: WorkspaceID(raw: 1), name: name, folder: folder, isWorktree: isWorktree,
            removedWorktreeName: removedWorktreeName)
    }

    private func path(_ name: String) -> URL {
        repoRoot
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
        guard let detail = (row as? SelectableRowView)?.detail, !detail.isEmpty else { return nil }
        return detail
    }

    private func listing(_ repo: URL, _ branches: String...) -> WorktreeListing {
        WorktreeListing(
            commonDir: repo.appendingPathComponent(".git"),
            worktrees: branches.map { worktree(repo, $0) })
    }

    private func workspace(_ title: String, path: URL = FileManager.default.temporaryDirectory)
        -> Workspace
    {
        Workspace(title: title, path: path, tabs: [], env: [:])
    }

    private func setKeymap(_ map: [Chord: KeyInterceptor.ReservedChord]) {
        let original = GeneralConfig.current
        var overridden = original
        overridden.keymap = map
        GeneralConfig.setCurrentForTesting(overridden)
        addTeardownBlock { GeneralConfig.setCurrentForTesting(original) }
    }

    private func makeRepoPicker(
        entries: [Workspace], open: [RunningWorkspace] = [], elsewhere: [RunningWorkspace] = [],
        current: WorkspaceID? = nil, removals: WorktreeRemovalTracker = WorktreeRemovalTracker(),
        openState: @escaping (URL) -> WorkspaceOpenState = { _ in .closed },
        onChoose: @escaping (Workspace, WorktreeOrigin?) -> Void = { _, _ in },
        onSwitch: @escaping (WorkspaceID) -> Void = { _ in },
        onReveal: @escaping (Int, WorkspaceID) -> Bool = { _, _ in true }
    ) -> RepoPickerOverlay {
        RepoPickerOverlay(
            entries: entries, open: open, elsewhere: elsewhere, current: current,
            removals: removals, openState: openState, onChoose: onChoose, onSwitch: onSwitch, onReveal: onReveal,
            onAddWorkspace: {}, onDismiss: {})
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
