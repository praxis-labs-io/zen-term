import AppKit
import XCTest

@testable import ZenTerm

/// Interaction tests for the diff viewer, driven through the real outline view in a window. The git
/// work is a fake `loader`, so no repo. State-only assertions would pass while the tree was dead, the
/// failure mode the project's interaction-test rule guards against.
final class DiffViewerOverlayTests: XCTestCase {
    private var window: NSWindow?

    override func tearDown() {
        window = nil
        super.tearDown()
    }

    // MARK: harness

    private final class LoaderSpy {
        var calls = 0
        /// The `base` the overlay asked each load for — nil on the default-base load, the picked branch
        /// after a base override.
        var lastBase: String?
        let status: GitDiffRunner.StatusLoad
        let failure: GitDiffRunner.Failure?
        let branches: [String]
        init(status: GitDiffRunner.StatusLoad, failure: GitDiffRunner.Failure?, branches: [String]) {
            self.status = status
            self.failure = failure
            self.branches = branches
        }
        func load(_ base: String?, _ completion: (DiffViewerOverlay.StatusResult) -> Void) {
            calls += 1
            lastBase = base
            if let failure {
                completion(.failure(failure))
            } else {
                completion(.success(status))
            }
        }
    }

    private func mount(
        unstaged: [FileDiff] = [], staged: [FileDiff] = [], committed: [FileDiff] = [],
        base: (branch: String, sha: String)? = nil, branches: [String] = [],
        failure: GitDiffRunner.Failure? = nil
    ) -> (overlay: DiffViewerOverlay, spy: LoaderSpy) {
        let status = GitDiffRunner.StatusLoad(
            unstaged: unstaged, staged: staged, committed: committed,
            baseBranch: base?.branch, baseSHA: base?.sha)
        let spy = LoaderSpy(status: status, failure: failure, branches: branches)
        let overlay = DiffViewerOverlay(
            background: Theme.current.chrome.background.nsColor,
            initialStatus: nil,
            loader: { base, completion in spy.load(base, completion) },
            branchesLoader: { completion in completion(spy.branches) },
            onCancel: {})
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.borderless], backing: .buffered, defer: false)
        win.contentView?.addSubview(overlay)
        overlay.frame = win.contentView!.bounds
        win.contentView?.layoutSubtreeIfNeeded()
        window = win
        return (overlay, spy)
    }

    private func file(_ path: String, added: Int = 1, removed: Int = 1) -> FileDiff {
        var lines: [DiffLine] = [DiffLine(kind: .context, oldLineNumber: 1, newLineNumber: 1, text: "ctx")]
        for index in 0..<removed {
            lines.append(DiffLine(kind: .removed, oldLineNumber: 2 + index, newLineNumber: nil, text: "old \(index)"))
        }
        for index in 0..<added {
            lines.append(DiffLine(kind: .added, oldLineNumber: nil, newLineNumber: 2 + index, text: "new \(index)"))
        }
        return FileDiff(
            path: path, oldPath: nil, changeKind: .modified,
            hunks: [Hunk(header: "@@ -1,3 +1,3 @@", oldStart: 1, newStart: 1, lines: lines)])
    }

    // MARK: tests

    func test_initialLoad_loadsOnceAndFillsTheTreeUnderASection() {
        let (overlay, spy) = mount(unstaged: [file("a/b/One.swift"), file("a/Two.swift")])

        XCTAssertEqual(spy.calls, 1)
        // Unstaged section + a / (b / One.swift) + Two.swift, expanded => 5 rows.
        XCTAssertEqual(overlay.treeRowCountForTesting, 5)
    }

    func test_load_autoSelectsFirstFileIntoTheRightPane() {
        let (overlay, _) = mount(unstaged: [file("a/b/One.swift"), file("a/Two.swift")])

        XCTAssertEqual(overlay.selectedFilePathForTesting, "a/b/One.swift")
        XCTAssertGreaterThan(overlay.diffRowCountForTesting, 0)
    }

    func test_selectingAFileInTheTree_drivesTheRightPane() {
        let (overlay, _) = mount(unstaged: [file("a/b/One.swift"), file("a/Two.swift")])

        // Rows: Unstaged=0, a=1, b=2, One.swift=3, Two.swift=4.
        overlay.selectRowForTesting(4)

        XCTAssertEqual(overlay.selectedFilePathForTesting, "a/Two.swift")
    }

    func test_selectingASectionRow_doesNotChangeTheShownFile() {
        let (overlay, _) = mount(unstaged: [file("a/b/One.swift"), file("a/Two.swift")])

        overlay.selectRowForTesting(0)  // the "Unstaged" section header (not selectable)

        XCTAssertEqual(overlay.selectedFilePathForTesting, "a/b/One.swift")  // unchanged
    }

    func test_multipleSlices_eachGetTheirOwnSection() {
        let (overlay, _) = mount(
            unstaged: [file("U.swift")], staged: [file("S.swift")], committed: [file("C.swift")],
            base: (branch: "main", sha: "abc1234"))

        // Three sections, each with one file => 6 rows (the base lives in the header, not the tree).
        XCTAssertEqual(overlay.treeRowCountForTesting, 6)
    }

    func test_emptyStatus_showsNoTreeAndNoSelectedFile() {
        let (overlay, _) = mount()

        XCTAssertEqual(overlay.treeRowCountForTesting, 0)
        XCTAssertNil(overlay.selectedFilePathForTesting)
    }

    func test_gitError_showsNoTreeAndNoSelectedFile() {
        let (overlay, _) = mount(failure: .gitError("fatal: bad thing"))

        XCTAssertEqual(overlay.treeRowCountForTesting, 0)
        XCTAssertNil(overlay.selectedFilePathForTesting)
    }

    // MARK: base dropdown

    func test_baseDropdown_shownWithTheBranchListAndCurrentBaseSelected_whenABaseResolves() {
        let (overlay, _) = mount(
            committed: [file("C.swift")], base: (branch: "main", sha: "abc1234"),
            branches: ["main", "feature-x"])

        XCTAssertTrue(overlay.isBaseHeaderShownForTesting)
        // The trigger reads "Base: <branch>"; the list rows stay bare branch names.
        XCTAssertEqual(overlay.baseDropdownForTesting.buttonTitleForTesting, "Base: main")
    }

    func test_baseDropdown_hidden_whenNoBaseResolves() {
        let (overlay, _) = mount(unstaged: [file("U.swift")])  // no committed slice, no base

        XCTAssertFalse(overlay.isBaseHeaderShownForTesting)
    }

    func test_choosingABranch_reloadsTheDiffAgainstThatBase() {
        let (overlay, spy) = mount(
            committed: [file("C.swift")], base: (branch: "main", sha: "abc1234"),
            branches: ["main", "feature-x"])
        let callsBefore = spy.calls

        overlay.chooseBaseForTesting("feature-x")

        XCTAssertEqual(spy.lastBase, "feature-x")  // the committed slice re-ran against the picked base
        XCTAssertGreaterThan(spy.calls, callsBefore)
    }

    func test_choosingTheCurrentBase_isANoOp() {
        let (overlay, spy) = mount(
            committed: [file("C.swift")], base: (branch: "main", sha: "abc1234"),
            branches: ["main", "feature-x"])
        let callsBefore = spy.calls

        overlay.chooseBaseForTesting("main")

        XCTAssertEqual(spy.calls, callsBefore)  // same base — no reload
    }
}
