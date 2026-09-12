import AppKit
import XCTest

@testable import ZenTerm

final class RepoPickerWorktreeChurnTests: WindowTestCase {
    private var root: URL!
    private var window: NSWindow?

    override func setUpWithError() throws {
        try super.setUpWithError()
        Motion.isReduceMotionEnabled = { true }
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenterm-wt-churn-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        GitRepoStatus.resetForTesting()
    }

    override func tearDownWithError() throws {
        window = nil
        GitRepoStatus.resetForTesting()
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    func test_aWorktreeRow_showsItsOwnCounts_notItsParents() throws {
        let repo = try GitFixture.makeRepo(at: root.appendingPathComponent("work", isDirectory: true))
        let linked = root.appendingPathComponent("linked", isDirectory: true)
        try GitFixture.run(["worktree", "add", "-b", "side", linked.path], in: repo)
        try GitFixture.write("loose\n", to: linked.appendingPathComponent("untracked.txt"))

        let overlay = RepoPickerOverlay(
            entries: [
                Workspace(
                    title: "work", path: repo, main: nil, right: nil, bottom: nil, focus: .main,
                    env: [:])
            ],
            background: Theme.current.chrome.background.nsColor,
            onChoose: { _, _ in }, onAddWorkspace: {}, onDismiss: {})
        mount(overlay)

        waitUntil(
            worktreeRow(in: overlay).map { counts(on: $0) == "?1" } ?? false,
            "the worktree row to show its untracked file", timeout: 10)
        let parent = try XCTUnwrap(
            overlay.rowViews.compactMap { $0 as? RepoPickerOverlay.RowView }
                .first { $0.worktree == nil })
        waitUntil(
            GitRepoStatus.churn(repo) != nil, "the parent's counts to land", timeout: 10)
        XCTAssertEqual(counts(on: parent), "", "the untracked file is the worktree's, not the parent's")
    }

    private func worktreeRow(in overlay: RepoPickerOverlay) -> RepoPickerOverlay.RowView? {
        overlay.rowViews.compactMap { $0 as? RepoPickerOverlay.RowView }
            .first { $0.worktree?.branch == "side" }
    }

    private func counts(on row: NSView) -> String? {
        descendants(of: row).compactMap { $0 as? NSTextField }
            .first { $0.lineBreakMode == .byClipping }?.stringValue
    }

    private func mount(_ overlay: PaletteOverlay) {
        overlay.translatesAutoresizingMaskIntoConstraints = true
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView?.addSubview(overlay)
        overlay.frame = NSRect(x: 0, y: 0, width: 560, height: 420)
        self.window = window
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}
