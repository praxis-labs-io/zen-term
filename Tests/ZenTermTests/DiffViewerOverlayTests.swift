import AppKit
import XCTest

@testable import ZenTerm

/// Interaction tests for the diff viewer, driven through the real outline view and scope selector in
/// a window. State-only assertions would pass while the tree or selector was dead — the failure mode
/// the project's interaction-test rule guards against. The git work is a fake `loader`, so no repo.
final class DiffViewerOverlayTests: XCTestCase {
    private var window: NSWindow?

    override func tearDown() {
        window = nil
        super.tearDown()
    }

    // MARK: harness

    private final class LoaderSpy {
        var requestedScopes: [DiffScope] = []
        var files: [FileDiff]
        var failure: GitDiffRunner.Failure?
        init(files: [FileDiff], failure: GitDiffRunner.Failure? = nil) {
            self.files = files
            self.failure = failure
        }
        func load(_ scope: DiffScope, _ completion: (DiffViewerOverlay.LoadResult) -> Void) {
            requestedScopes.append(scope)
            if let failure {
                completion(.failure(failure))
            } else {
                completion(
                    .success(
                        GitDiffRunner.DiffLoad(scope: scope, baseBranch: "main", baseSHA: "abc1234", files: files)))
            }
        }
    }

    private func mount(files: [FileDiff], failure: GitDiffRunner.Failure? = nil, notARepo: Bool = false)
        -> (overlay: DiffViewerOverlay, spy: LoaderSpy)
    {
        let spy = LoaderSpy(files: files, failure: failure)
        let loader: DiffViewerOverlay.Loader? =
            notARepo ? nil : { scope, completion in spy.load(scope, completion) }
        let overlay = DiffViewerOverlay(
            background: Theme.current.chrome.background.nsColor, loader: loader, onCancel: {})
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

    func test_initialLoad_requestsBranchScopeAndFillsTheTree() {
        let (overlay, spy) = mount(files: [file("a/b/One.swift"), file("a/Two.swift")])

        XCTAssertEqual(spy.requestedScopes, [.branch])  // default scope is All (.branch)
        // Tree: a / (b / One.swift) + Two.swift, expanded => 4 rows.
        XCTAssertEqual(overlay.treeRowCountForTesting, 4)
        XCTAssertEqual(overlay.shownScopeForTesting, .branch)
    }

    func test_load_autoSelectsFirstFileIntoTheRightPane() {
        let (overlay, _) = mount(files: [file("a/b/One.swift"), file("a/Two.swift")])

        XCTAssertEqual(overlay.selectedFilePathForTesting, "a/b/One.swift")
        XCTAssertGreaterThan(overlay.diffRowCountForTesting, 0)
    }

    func test_selectingAFileInTheTree_drivesTheRightPane() {
        let (overlay, _) = mount(files: [file("a/b/One.swift"), file("a/Two.swift")])

        // Row 3 is Two.swift (rows: a=0, b=1, One.swift=2, Two.swift=3).
        overlay.selectRowForTesting(3)

        XCTAssertEqual(overlay.selectedFilePathForTesting, "a/Two.swift")
        XCTAssertGreaterThan(overlay.diffRowCountForTesting, 0)
    }

    func test_selectingADirectoryRow_doesNotChangeTheShownFile() {
        let (overlay, _) = mount(files: [file("a/b/One.swift"), file("a/Two.swift")])

        overlay.selectRowForTesting(0)  // the "a" directory row

        XCTAssertEqual(overlay.selectedFilePathForTesting, "a/b/One.swift")  // unchanged
    }

    func test_scopeSelector_reRequestsTheDiffForTheChosenScope() {
        let (overlay, spy) = mount(files: [file("One.swift")])
        XCTAssertEqual(spy.requestedScopes, [.branch])  // default is All (.branch), index 0

        overlay.selectScopeForTesting(2)  // "Uncommitted" (order: All · Committed · Uncommitted)
        XCTAssertEqual(spy.requestedScopes.last, .uncommitted)
        XCTAssertEqual(overlay.shownScopeForTesting, .uncommitted)

        overlay.selectScopeForTesting(1)  // "Committed"
        XCTAssertEqual(spy.requestedScopes.last, .committed)
        XCTAssertEqual(overlay.shownScopeForTesting, .committed)
    }

    func test_emptyScope_showsNoTreeAndNoSelectedFile() {
        let (overlay, _) = mount(files: [])

        XCTAssertEqual(overlay.treeRowCountForTesting, 0)
        XCTAssertNil(overlay.selectedFilePathForTesting)
    }

    func test_notARepo_showsNoTreeAndNeverRequestsALoad() {
        let (overlay, spy) = mount(files: [], notARepo: true)

        XCTAssertEqual(overlay.treeRowCountForTesting, 0)
        XCTAssertNil(overlay.selectedFilePathForTesting)
        XCTAssertTrue(spy.requestedScopes.isEmpty)
    }
}
