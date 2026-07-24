import AppKit
import XCTest

@testable import ZenTerm

/// The overlay's highlight orchestration (ZEN-239): which spans reach the rendered rows, and when the
/// cache is dropped. These paths can be silently dead — if the cache-hit branch stopped painting, a
/// revisited or reopened file would render nothing; if the cache stopped being cleared on a changed
/// reload, stale spans would paint over new content — and the suite would stay green either way.
/// Colors on screen remain the runbook's; this asserts only presence/staleness of spans.
final class DiffViewerHighlightOrchestrationTests: XCTestCase {
    private var window: NSWindow?

    override func tearDown() {
        window = nil
        super.tearDown()
    }

    /// Serves the initial status once, then a different one — so the second load is a *changed* reload.
    /// (A load returning an identical status is a deliberate no-op that keeps the view, and the cache.)
    private final class ChangingLoaderSpy {
        private let statuses: [GitDiffRunner.StatusLoad]
        private var calls = 0
        init(_ statuses: [GitDiffRunner.StatusLoad]) { self.statuses = statuses }
        func load(_ base: String?, _ completion: (DiffViewerOverlay.StatusResult) -> Void) {
            let status = statuses[min(calls, statuses.count - 1)]
            calls += 1
            completion(.success(status))
        }
    }

    private func file(_ path: String, text: String = "let x = 1") -> FileDiff {
        FileDiff(
            path: path, oldPath: nil, changeKind: .modified,
            hunks: [
                Hunk(
                    header: "@@ -1,1 +1,1 @@", oldStart: 1, newStart: 1,
                    lines: [DiffLine(kind: .context, oldLineNumber: 1, newLineNumber: 1, text: text)])
            ])
    }

    private func status(_ files: [FileDiff], branches: [String] = []) -> GitDiffRunner.StatusLoad {
        GitDiffRunner.StatusLoad(
            unstaged: files, staged: [], committed: [],
            baseBranch: "main", baseSHA: "abc1234", currentBranch: "feature")
    }

    private func mount(
        store: DiffHighlightStore, loader: @escaping DiffViewerOverlay.Loader,
        initialStatus: GitDiffRunner.StatusLoad? = nil, branches: [String] = ["main", "develop"],
        // Non-existent by default: the highlighter no-ops and never spawns git, so what lands in the
        // rows comes only from the store — which is what most of these tests are about. Pass a real
        // directory to exercise the branch that waits on a highlight.
        repoRoot: URL = URL(fileURLWithPath: "/var/empty/zenterm-tests-no-repo")
    ) -> DiffViewerOverlay {
        let overlay = DiffViewerOverlay(
            background: Theme.current.chrome.background.nsColor,
            repoName: "repo",
            repoRoot: repoRoot,
            highlightStore: store,
            initialStatus: initialStatus,
            loader: loader,
            branchesLoader: { completion in completion(branches) },
            sendTargets: { [] },
            sender: { _, _, _ in },
            onCancel: {})
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 600),
            styleMask: [.borderless], backing: .buffered, defer: false)
        win.contentView?.addSubview(overlay)
        overlay.frame = win.contentView!.bounds
        win.contentView?.layoutSubtreeIfNeeded()
        window = win
        return overlay
    }

    private func spans(of rows: [DiffRow]) -> [TokenSpan] {
        rows.flatMap { row -> [TokenSpan] in
            switch row {
            case .split(let left, let right): return (left?.spans ?? []) + (right?.spans ?? [])
            case .unified(_, _, _, _, let spans): return spans ?? []
            case .hunkHeader: return []
            }
        }
    }

    func test_cachedSpans_paintOnTheFirstRender_onAWarmReopen() {
        // A warm reopen (the WindowController hands back the repo's last status *and* its highlight
        // store) must paint highlighted on the very first render — the cache-hit branch is the only
        // thing that paints there. A cold open deliberately clears instead: with no prior status it
        // can't know the content is unchanged (see `test_changedReload_dropsTheCachedSpans`).
        let diff = file("A.swift")
        let store = DiffHighlightStore()
        let expected = TokenSpan(range: NSRange(location: 0, length: 3), role: .keyword)
        store.store(diff.highlightKey, DiffFileSpans(old: [1: [expected]], new: [:]))
        let load = status([diff])

        let overlay = mount(
            store: store, loader: { _, completion in completion(.success(load)) }, initialStatus: load)

        XCTAssertEqual(overlay.selectedFilePathForTesting, "A.swift")
        XCTAssertEqual(spans(of: overlay.renderedDiffRowsForTesting), [expected])
    }

    func test_selectingAnUncachedFile_clearsThePaneRatherThanLeavingThePreviousFileOnScreen() throws {
        // With a real repo root the "supported but uncached" branch runs, which withholds the paint
        // until the highlight lands. It has to clear the pane first: otherwise the file you just
        // clicked shows the *previous* file's diff until the parse finishes (up to the safety cap on a
        // big file or slow storage), which reads as a click that did nothing.
        let repo = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("zenterm-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repo) }

        let first = file("A.swift")
        let second = file("B.swift")
        let store = DiffHighlightStore()
        // Seed the first file so it paints real rows immediately; those are what must not linger.
        store.store(
            first.highlightKey,
            DiffFileSpans(old: [1: [TokenSpan(range: NSRange(location: 0, length: 3), role: .keyword)]], new: [:]))
        let load = status([first, second])
        let overlay = mount(
            store: store, loader: { _, completion in completion(.success(load)) },
            initialStatus: load, repoRoot: repo)

        XCTAssertEqual(overlay.selectedFilePathForTesting, "A.swift")
        XCTAssertFalse(overlay.renderedDiffRowsForTesting.isEmpty, "precondition: the first file painted")

        // Row 0 is the "Unstaged" section header, then A.swift, then B.swift.
        overlay.selectRowForTesting(2)

        XCTAssertEqual(overlay.selectedFilePathForTesting, "B.swift")
        XCTAssertTrue(
            overlay.renderedDiffRowsForTesting.isEmpty,
            "the pane must clear while awaiting the highlight, not keep showing A.swift's diff")
    }

    func test_unhighlightableFile_isResolvedInTheCacheSoItIsNotRetried() {
        // No repo on disk => this file will never highlight. It must be recorded as resolved-to-nil, or
        // every re-render would kick a fresh (pointless) highlight.
        let diff = file("A.swift")
        let store = DiffHighlightStore()
        let load = status([diff])

        _ = mount(store: store, loader: { _, completion in completion(.success(load)) })

        guard let cached = store.cached(diff.highlightKey) else {
            return XCTFail("an unhighlightable file should still be cached as resolved")
        }
        XCTAssertNil(cached, "resolved-but-no-spans is cached as nil, not left absent")
    }

    func test_changedReload_dropsTheCachedSpansOfEveryFile() {
        // A refresh that finds changed content invalidates *every* cached span set — they were computed
        // from the previous revision's blobs, so keeping any would paint stale colors on new text.
        //
        // Asserted on a file the reload does NOT re-render (only the first file is selected): the
        // selected file's entry gets overwritten by its own re-render regardless, so asserting on it
        // would pass even with the clear removed.
        let selected = file("A.swift")
        let other = file("B.swift")
        let store = DiffHighlightStore()
        let spy = ChangingLoaderSpy([
            status([selected, other]),
            status([file("A.swift", text: "let y = 2"), other]),
        ])
        let overlay = mount(store: store, loader: { base, completion in spy.load(base, completion) })

        let stale = DiffFileSpans(
            old: [1: [TokenSpan(range: NSRange(location: 0, length: 3), role: .keyword)]], new: [:])
        store.store(other.highlightKey, stale)
        XCTAssertNotNil(store.cached(other.highlightKey), "precondition: cached before the refresh")

        overlay.reloadForTesting()  // second load carries different content

        XCTAssertNil(
            store.cached(other.highlightKey) ?? nil,
            "a reload that changed the content must drop spans computed against the old revision")
    }

    func test_unchangedReload_keepsTheCachedSpans() {
        // The mirror image: an identical refresh is a no-op, so a reopen on unchanged content still
        // paints highlighted immediately instead of re-parsing every file.
        let diff = file("A.swift")
        let store = DiffHighlightStore()
        let load = status([diff])
        let overlay = mount(store: store, loader: { _, completion in completion(.success(load)) })

        let cached = DiffFileSpans(
            old: [1: [TokenSpan(range: NSRange(location: 0, length: 3), role: .keyword)]], new: [:])
        store.store(diff.highlightKey, cached)

        overlay.reloadForTesting()  // same content

        XCTAssertEqual(store.cached(diff.highlightKey) ?? nil, cached, "unchanged reload must keep the cache")
    }
}
