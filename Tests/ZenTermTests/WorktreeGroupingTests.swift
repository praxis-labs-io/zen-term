import XCTest

@testable import ZenTerm

/// Which workspace shows a repo's worktrees, and which of them it shows. Two lists read this, and
/// getting it wrong renders one folder twice with a Remove button on each copy.
final class WorktreeGroupingTests: XCTestCase {
    private func workspace(_ title: String, _ path: String) -> Workspace {
        Workspace(
            title: title, path: URL(fileURLWithPath: path), main: nil, right: nil, bottom: nil,
            focus: .main, env: [:])
    }

    private func worktree(_ path: String, branch: String) -> Worktree {
        Worktree(path: URL(fileURLWithPath: path), branch: branch, head: "abc1234", isLocked: false)
    }

    private func listing(_ commonDir: String?, _ worktrees: [Worktree]) -> WorktreeListing {
        WorktreeListing(commonDir: commonDir.map { URL(fileURLWithPath: $0) }, worktrees: worktrees)
    }

    // MARK: owners

    /// Two workspaces can be checkouts of one repo, and `worktree list` answers the same set for
    /// both. Config order decides, so a re-sorted or filtered list cannot move ownership.
    func test_oneRepoTwoWorkspaces_theFirstInConfigOrderClaimsIt() {
        let first = workspace("First", "/repo")
        let second = workspace("Second", "/repo-checkout")
        let listings = [
            first.path: listing("/repo/.git", [worktree("/wt/one", branch: "one")]),
            second.path: listing("/repo/.git", [worktree("/wt/one", branch: "one")]),
        ]
        let owners = WorktreeGrouping.owners(among: [first, second], listings: listings)
        XCTAssertEqual(owners[URL(fileURLWithPath: "/repo/.git")], first.path)

        XCTAssertEqual(
            WorktreeGrouping.worktrees(
                of: first, listings: listings, owners: owners, configured: []
            ).map(\.branch), ["one"])
        XCTAssertEqual(
            WorktreeGrouping.worktrees(
                of: second, listings: listings, owners: owners, configured: []
            ).count, 0)
    }

    /// A workspace inside a repo but not at its root resolves a common dir and lists nothing.
    /// Claiming there would hide the real checkout's worktrees.
    func test_anEmptyListingNeverClaims() {
        let inner = workspace("Inner", "/repo/src")
        let root = workspace("Root", "/repo")
        let listings = [
            inner.path: listing("/repo/.git", []),
            root.path: listing("/repo/.git", [worktree("/wt/one", branch: "one")]),
        ]
        let owners = WorktreeGrouping.owners(among: [inner, root], listings: listings)
        XCTAssertEqual(owners[URL(fileURLWithPath: "/repo/.git")], root.path)
    }

    /// Nothing has answered for this workspace yet, so it shows no children rather than guessing.
    func test_aWorkspaceWithNoListingShowsNothing() {
        let only = workspace("Only", "/repo")
        XCTAssertEqual(
            WorktreeGrouping.worktrees(of: only, listings: [:], owners: [:], configured: []).count, 0)
    }

    // MARK: what a workspace shows

    /// A worktree the user configured as a workspace of its own already has a row of its own.
    func test_aWorktreeThatIsItsOwnWorkspaceIsDropped() {
        let root = workspace("Root", "/repo")
        let listings = [
            root.path: listing(
                "/repo/.git",
                [worktree("/wt/one", branch: "one"), worktree("/wt/two", branch: "two")])
        ]
        let owners = WorktreeGrouping.owners(among: [root], listings: listings)
        let shown = WorktreeGrouping.worktrees(
            of: root, listings: listings, owners: owners,
            configured: [URL(fileURLWithPath: "/wt/one")])
        XCTAssertEqual(shown.map(\.branch), ["two"])
    }

    func test_worktreesKeepTheOrderGitListedThemIn() {
        let root = workspace("Root", "/repo")
        let listings = [
            root.path: listing(
                "/repo/.git",
                [
                    worktree("/wt/c", branch: "c"), worktree("/wt/a", branch: "a"),
                    worktree("/wt/b", branch: "b"),
                ])
        ]
        let owners = WorktreeGrouping.owners(among: [root], listings: listings)
        XCTAssertEqual(
            WorktreeGrouping.worktrees(
                of: root, listings: listings, owners: owners, configured: []
            ).map(\.branch), ["c", "a", "b"])
    }

    /// Outside a repo `commonDir` is nil, so the workspace's own path stands in as the key and two
    /// unrelated folders cannot collapse into one group.
    func test_aNilCommonDirFallsBackToTheWorkspacesOwnPath() {
        let one = workspace("One", "/plain-one")
        let two = workspace("Two", "/plain-two")
        let listings = [
            one.path: listing(nil, [worktree("/wt/one", branch: "one")]),
            two.path: listing(nil, [worktree("/wt/two", branch: "two")]),
        ]
        let owners = WorktreeGrouping.owners(among: [one, two], listings: listings)
        XCTAssertEqual(
            WorktreeGrouping.worktrees(
                of: one, listings: listings, owners: owners, configured: []
            ).map(\.branch), ["one"])
        XCTAssertEqual(
            WorktreeGrouping.worktrees(
                of: two, listings: listings, owners: owners, configured: []
            ).map(\.branch), ["two"])
    }
}
