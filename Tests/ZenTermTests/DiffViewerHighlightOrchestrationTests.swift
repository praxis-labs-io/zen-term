import AppKit
import XCTest

@testable import ZenTerm

/// The overlay's highlight orchestration (ZEN-239): which spans reach the rendered rows, and when the
/// cache is dropped. These paths can be silently dead — if the cache-hit branch stopped painting, a
/// revisited or reopened file would render nothing; if the cache stopped being cleared on a changed
/// reload, stale spans would paint over new content — and the suite would stay green either way.
/// Colors on screen remain the runbook's; this asserts only presence/staleness of spans.
final class DiffViewerHighlightOrchestrationTests: WindowTestCase {
    private var window: NSWindow?
    private var originalConfig: GeneralConfig!

    override func setUp() {
        super.setUp()
        // Pin the diff-layout default so the tester's own config (or a prior test's leftover) can't decide
        // the layout: a span lands in different rows in side-by-side vs inline, and `spans(of:)` reads them
        // differently, so an ambient layout made this pass or fail by test order (ZEN-239 isolation).
        originalConfig = GeneralConfig.current
        GeneralConfig.setCurrentForTesting(.builtIn)
    }

    override func tearDown() {
        GeneralConfig.setCurrentForTesting(originalConfig)
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

    /// A fresh session for one repo. The root is non-existent by default: the highlighter no-ops and
    /// never spawns git, so what lands in the rows comes only from the session's store — which is what
    /// most of these tests are about. Pass a real directory to exercise the branch that waits on a
    /// highlight.
    private func makeSession(
        repoRoot: URL = URL(fileURLWithPath: "/var/empty/zenterm-tests-no-repo")
    ) -> DiffViewerSession {
        DiffViewerSession(repoRoot: repoRoot)
    }

    private func mount(
        session: DiffViewerSession, loader: @escaping DiffViewerOverlay.Loader,
        branches: [String] = ["main", "develop"]
    ) -> DiffViewerOverlay {
        let overlay = DiffViewerOverlay(
            background: Theme.current.chrome.background.nsColor,
            session: session,
            loader: loader,
            branchesLoader: { completion in completion(branches) },
            headsLoader: { completion in completion([]) },
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
        let session = makeSession()
        let store = session.highlights
        let expected = TokenSpan(range: NSRange(location: 0, length: 3), role: .keyword)
        store.store(diff.highlightKey, DiffFileSpans(old: [1: [expected]], new: [:]))
        let load = status([diff])
        session.lastStatus = load

        let overlay = mount(session: session, loader: { _, _, completion in completion(.success(load)) })

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
        let session = makeSession(repoRoot: repo)
        let store = session.highlights
        // Seed the first file so it paints real rows immediately; those are what must not linger.
        store.store(
            first.highlightKey,
            DiffFileSpans(old: [1: [TokenSpan(range: NSRange(location: 0, length: 3), role: .keyword)]], new: [:]))
        let load = status([first, second])
        session.lastStatus = load
        let overlay = mount(session: session, loader: { _, _, completion in completion(.success(load)) })

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
        let session = makeSession()
        let store = session.highlights
        let load = status([diff])

        _ = mount(session: session, loader: { _, _, completion in completion(.success(load)) })

        guard let cached = store.cached(diff.highlightKey) else {
            return XCTFail("an unhighlightable file should still be cached as resolved")
        }
        XCTAssertNil(cached, "resolved-but-no-spans is cached as nil, not left absent")
    }

    func test_changedReload_dropsTheChangedFilesSpansButKeepsTheUnchangedOnes() {
        // A refresh that finds changed content must invalidate the spans of the file that *changed* —
        // they were computed from the old revision's blobs, so keeping them would paint stale colors on
        // new text. But a file that DIDN'T change keeps its spans: re-parsing it would blank and re-fetch
        // it for nothing, which made a warm reopen re-parse the whole repo like a cold open (ZEN-261).
        //
        // Both files here are unselected (only the first, `selected`, is auto-picked): a selected file's
        // entry gets overwritten by its own re-render regardless, so asserting on the two others isolates
        // the eviction logic itself.
        let selected = file("A.swift")
        let changed = file("B.swift", text: "let x = 1")
        let untouched = file("C.swift")
        let session = makeSession()
        let store = session.highlights
        let spy = ChangingLoaderSpy([
            status([selected, changed, untouched]),
            status([selected, file("B.swift", text: "let y = 2"), untouched]),  // only B changed
        ])
        let overlay = mount(session: session, loader: { base, _, completion in spy.load(base, completion) })

        let spans = DiffFileSpans(
            old: [1: [TokenSpan(range: NSRange(location: 0, length: 3), role: .keyword)]], new: [:])
        store.store(changed.highlightKey, spans)
        store.store(untouched.highlightKey, spans)

        overlay.reloadForTesting()  // second load: B's content moved, C's didn't

        XCTAssertNil(
            store.cached(changed.highlightKey) ?? nil,
            "the changed file's spans, computed against the old revision, must drop")
        XCTAssertEqual(
            store.cached(untouched.highlightKey) ?? nil, spans,
            "the unchanged file keeps its spans — no re-parse, no cold-open flash (ZEN-261)")
    }

    func test_unchangedReload_keepsTheCachedSpans() {
        // The mirror image: an identical refresh is a no-op, so a reopen on unchanged content still
        // paints highlighted immediately instead of re-parsing every file.
        let diff = file("A.swift")
        let session = makeSession()
        let store = session.highlights
        let load = status([diff])
        let overlay = mount(session: session, loader: { _, _, completion in completion(.success(load)) })

        let cached = DiffFileSpans(
            old: [1: [TokenSpan(range: NSRange(location: 0, length: 3), role: .keyword)]], new: [:])
        store.store(diff.highlightKey, cached)

        overlay.reloadForTesting()  // same content

        XCTAssertEqual(store.cached(diff.highlightKey) ?? nil, cached, "unchanged reload must keep the cache")
    }
}
