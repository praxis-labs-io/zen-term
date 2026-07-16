import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

/// Lifecycle tests for the tool-float engine (ZEN-77): drive `toggleToolFloat` on a window-mounted
/// controller and assert what the `persist:` mode does to the underlying surface. Asserts through
/// the real spawn/terminate path (`RecordingSurface.startCount` / `.terminated`) rather than the
/// registry, because a state-only test would pass while the surface was actually being killed.
final class TabControllerToolFloatTests: XCTestCase {
    private var windows: [NSWindow] = []
    private var controllers: [TabController] = []
    private var root = FileManager.default.temporaryDirectory

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenterm-floats-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        controllers.forEach { $0.shutdown() }
        controllers = []
        windows = []
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    // MARK: harness

    private func makeDir(_ name: String, git: Bool) throws -> URL {
        let dir = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if git {
            try FileManager.default.createDirectory(
                at: dir.appendingPathComponent(".git", isDirectory: true), withIntermediateDirectories: true)
        }
        return dir
    }

    /// A window-mounted controller over `cwd`, recording every surface it spawns.
    private func makeController(cwd: URL) -> (controller: TabController, spawned: () -> [RecordingSurface]) {
        var spawned: [RecordingSurface] = []
        let controller = TabController(
            initialCWD: cwd,
            makeSurface: {
                let surface = RecordingSurface()
                spawned.append(surface)
                return surface
            })
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.borderless], backing: .buffered, defer: false)
        controller.view.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        window.contentView?.addSubview(controller.view)
        controller.view.layoutSubtreeIfNeeded()
        // Boot the first pane. `start()` is what mints the pane's surface, and `focusedCWD` reads
        // that surface's `currentDirectory` first — so without it there is no pane, the first
        // spawn recorded is a float, and `focusedCWD` can never move off `initialCWD`. A cwd-drift
        // test would then silently assert nothing.
        controller.start()
        windows.append(window)
        controllers.append(controller)
        return (controller, { spawned })
    }

    private func spec(
        _ id: String, persist: ToolFloat.Persistence, git: Bool = false, dir: URL? = nil,
        command: String? = nil
    ) -> ToolFloat {
        ToolFloat(
            id: id, title: "Open \(id)", icon: ToolFloatParser.defaultIcon, command: command ?? id,
            dir: dir, widthFraction: 0.85, heightFraction: 0.85, requiresGitRepo: git,
            persist: persist, toggle: Chord(command: true, shift: true, key: "j"))
    }

    /// The float surfaces only — filtered by the command the spec launches, so the tab's own pane
    /// surface never counts.
    private func floatSurfaces(_ spawned: [RecordingSurface], command: String) -> [RecordingSurface] {
        spawned.filter { $0.lastConfig?.args == ["-l", "-i", "-c", command] }
    }

    /// The tab's initial pane surface — the one `focusedCWD` reads `currentDirectory` from.
    private func paneSurface(_ spawned: [RecordingSurface]) -> RecordingSurface { spawned[0] }

    // MARK: tests

    func test_ephemeralFloat_terminatesOnDismiss() throws {
        let dir = try makeDir("plain", git: false)
        let (controller, spawned) = makeController(cwd: dir)
        let float = spec("yazi", persist: .ephemeral)

        controller.toggleToolFloat(float)
        let opened = floatSurfaces(spawned(), command: "yazi")
        XCTAssertEqual(opened.count, 1)

        controller.closeToolFloat()
        XCTAssertTrue(opened[0].terminated, "an ephemeral float must die on dismiss")

        controller.toggleToolFloat(float)
        XCTAssertEqual(floatSurfaces(spawned(), command: "yazi").count, 2, "reopen spawns fresh")
    }

    func test_dirFloat_survivesDismiss_andReusesSurfaceOnReopen() throws {
        let repo = try makeDir("repo", git: true)
        let (controller, spawned) = makeController(cwd: repo)
        let float = spec("lazygit", persist: .directory)

        controller.toggleToolFloat(float)
        let first = floatSurfaces(spawned(), command: "lazygit")
        XCTAssertEqual(first.count, 1)

        controller.closeToolFloat()
        XCTAssertFalse(first[0].terminated, "a persistent float must survive dismiss")

        controller.toggleToolFloat(float)
        XCTAssertEqual(
            floatSurfaces(spawned(), command: "lazygit").count, 1, "reopen must reuse, not respawn")
        XCTAssertEqual(first[0].startCount, 1, "the retained surface must not be restarted")
    }

    func test_dirFloat_respawnsWhenAnchorChanges() throws {
        let repoA = try makeDir("a", git: true)
        let repoB = try makeDir("b", git: true)
        let (controller, spawned) = makeController(cwd: repoA)
        let float = spec("lazygit", persist: .directory)

        controller.toggleToolFloat(float)
        let first = floatSurfaces(spawned(), command: "lazygit")[0]
        controller.closeToolFloat()

        paneSurface(spawned()).currentDirectory = repoB  // the focused pane cd'd to another repo
        controller.toggleToolFloat(float)

        XCTAssertTrue(first.terminated, "the stale instance must be discarded")
        let all = floatSurfaces(spawned(), command: "lazygit")
        XCTAssertEqual(all.count, 2, "a new repo gets a new instance")
        XCTAssertEqual(all[1].lastConfig?.workingDirectory, repoB)
    }

    func test_dirFloat_anchorsToRepoRoot_soSubdirReusesTheInstance() throws {
        let repo = try makeDir("repo", git: true)
        let sub = repo.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let (controller, spawned) = makeController(cwd: repo)
        let float = spec("lazygit", persist: .directory)

        controller.toggleToolFloat(float)
        controller.closeToolFloat()
        paneSurface(spawned()).currentDirectory = sub  // same repo, different subdir
        controller.toggleToolFloat(float)

        XCTAssertEqual(
            floatSurfaces(spawned(), command: "lazygit").count, 1,
            "cd'ing within one repo must not reload the float")
    }

    func test_dirFloat_outsideARepo_anchorsToThePlainCWD() throws {
        let dirA = try makeDir("plain-a", git: false)
        let dirB = try makeDir("plain-b", git: false)
        let (controller, spawned) = makeController(cwd: dirA)
        let float = spec("btm", persist: .directory)

        controller.toggleToolFloat(float)
        controller.closeToolFloat()
        controller.toggleToolFloat(float)
        XCTAssertEqual(floatSurfaces(spawned(), command: "btm").count, 1, "same dir reuses")

        controller.closeToolFloat()
        paneSurface(spawned()).currentDirectory = dirB
        controller.toggleToolFloat(float)
        XCTAssertEqual(floatSurfaces(spawned(), command: "btm").count, 2, "a different dir respawns")
    }

    func test_persistentFloat_terminatedOnShutdown() throws {
        let dir = try makeDir("plain", git: false)
        let (controller, spawned) = makeController(cwd: dir)

        controller.toggleToolFloat(spec("btop", persist: .directory))
        let surface = floatSurfaces(spawned(), command: "btop")[0]
        controller.closeToolFloat()
        XCTAssertFalse(surface.terminated)

        controller.shutdown()
        XCTAssertTrue(surface.terminated, "a hidden persistent float must not outlive its tab")
    }

    func test_persistentFloat_processExit_clearsRegistry_soNextOpenSpawnsFresh() throws {
        let dir = try makeDir("plain", git: false)
        let (controller, spawned) = makeController(cwd: dir)
        let float = spec("lazygit", persist: .directory)

        controller.toggleToolFloat(float)
        let first = floatSurfaces(spawned(), command: "lazygit")[0]
        controller.surfaceDidExit(first, code: 0)  // `q` inside the tool

        controller.toggleToolFloat(float)
        XCTAssertEqual(
            floatSurfaces(spawned(), command: "lazygit").count, 2,
            "a quit tool must spawn fresh on the next open, not resurrect a dead surface")
    }

    func test_hiddenPersistentFloat_processExit_clearsRegistry() throws {
        let dir = try makeDir("plain", git: false)
        let (controller, spawned) = makeController(cwd: dir)
        let float = spec("lazygit", persist: .directory)

        controller.toggleToolFloat(float)
        let first = floatSurfaces(spawned(), command: "lazygit")[0]
        controller.closeToolFloat()
        controller.surfaceDidExit(first, code: 0)  // the tool died while hidden

        controller.toggleToolFloat(float)
        XCTAssertEqual(floatSurfaces(spawned(), command: "lazygit").count, 2)
    }

    // MARK: overlay slot / view re-host (regression coverage for the review-fix pass)

    /// Reopening a persistent float while its old card is still springing out must re-host the
    /// shared `surface.view` in the NEW card and drop the old one from the view tree — not leave
    /// both fighting over the same view's constraints. Walks the real view hierarchy
    /// (`surface.view.superview`) rather than the private `dismissingFloatOverlay`/`persistentFloats`
    /// state, so a broken re-host would fail this test even if the bookkeeping looked fine.
    func test_persistentFloat_reopenBeforeDismissAnimationCompletes_rehostsView_dropsOldCard() throws {
        Motion.isReduceMotionEnabled = { false }  // force the async path so the old card is still parked
        defer { Motion.isReduceMotionEnabled = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion } }
        let dir = try makeDir("plain", git: false)
        let (controller, spawned) = makeController(cwd: dir)
        let float = spec("btop", persist: .directory)

        controller.toggleToolFloat(float)
        let surface = floatSurfaces(spawned(), command: "btop")[0]
        let oldOverlay = surface.view.superview?.superview
        XCTAssertNotNil(oldOverlay, "the surface's view must be hosted inside a float card")

        controller.closeToolFloat()  // a persistent dismiss parks the still-springing-out card
        controller.toggleToolFloat(float)  // reopen before its exit animation finishes

        let newOverlay = surface.view.superview?.superview
        XCTAssertNotNil(newOverlay?.superview, "the view must be re-hosted in a card that's actually on screen")
        XCTAssertTrue(oldOverlay !== newOverlay, "reopening must build a new card, not reuse the dismissing one")
        XCTAssertNil(oldOverlay?.superview, "the old dismissing card must be detached, not left dangling on screen")
    }

    /// Reduce Motion completes `Motion.springScaleFade`'s completion synchronously (see
    /// `MotionTests`), so `closeToolFloat` must park the outgoing overlay in `dismissingFloatOverlay`
    /// BEFORE calling `animateOut` — parking it after would assign a strong reference the
    /// already-run completion never gets a chance to clear, stranding the card. Proven with a weak
    /// reference (no private-state peeking): if the card is truly dropped, every strong ref to it
    /// is gone the instant `closeToolFloat` returns and ARC deallocates it synchronously.
    func test_persistentFloat_dismissUnderReduceMotion_doesNotStrandTheOverlay() throws {
        Motion.isReduceMotionEnabled = { true }
        defer { Motion.isReduceMotionEnabled = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion } }
        let dir = try makeDir("plain", git: false)
        let (controller, spawned) = makeController(cwd: dir)
        let float = spec("btop", persist: .directory)

        weak var weakOverlay: SurfaceFloatOverlay?
        // AppKit views are autoreleased, so a weak ref doesn't clear the instant the last strong ref
        // drops — it clears when the pool drains. Do the open/close inside the pool so the assertion
        // measures stranding rather than autorelease timing.
        autoreleasepool {
            controller.toggleToolFloat(float)
            let surface = floatSurfaces(spawned(), command: "btop")[0]
            weakOverlay = surface.view.superview?.superview as? SurfaceFloatOverlay
            XCTAssertNotNil(weakOverlay, "the surface's view must be hosted inside a float card")

            controller.closeToolFloat()  // Reduce Motion runs `animateOut`'s completion synchronously
        }

        XCTAssertNil(
            weakOverlay,
            "a synchronously-completed dismiss must drop every strong ref to the card — a stray "
                + "`dismissingFloatOverlay` assignment after the fact would strand it")

        controller.toggleToolFloat(float)  // reopening after must still reuse, not respawn
        XCTAssertEqual(floatSurfaces(spawned(), command: "btop").count, 1)
    }

    func test_dirField_pinsTheSpawnDirectory_ignoringTheFocusedCWD() throws {
        let paneDir = try makeDir("pane", git: false)
        let pinned = try makeDir("notes", git: false)
        let (controller, spawned) = makeController(cwd: paneDir)

        controller.toggleToolFloat(spec("notes", persist: .ephemeral, dir: pinned))

        XCTAssertEqual(
            floatSurfaces(spawned(), command: "notes")[0].lastConfig?.workingDirectory, pinned,
            "a pinned dir: must win over the focused pane's cwd")
    }

    /// A pinned `dir:` gives a `persist:dir` float a FIXED identity, so the re-anchor comparison
    /// can never fire — the intended way to keep a tool alive at one place. Proven at the engine
    /// level by doing exactly what forces a respawn for an unpinned `persist:dir` float — see
    /// `test_dirFloat_respawnsWhenAnchorChanges` — and asserting it does NOT happen here.
    func test_dirField_pinnedAnchor_neverReanchorsOnCWDChange() throws {
        let paneDir = try makeDir("pane", git: false)
        let pinned = try makeDir("notes", git: false)
        let elsewhere = try makeDir("elsewhere", git: false)
        let (controller, spawned) = makeController(cwd: paneDir)
        let float = spec("notes", persist: .directory, dir: pinned)

        controller.toggleToolFloat(float)
        let first = floatSurfaces(spawned(), command: "notes")[0]
        controller.closeToolFloat()

        paneSurface(spawned()).currentDirectory = elsewhere  // would force a respawn without a pinned dir:
        controller.toggleToolFloat(float)

        XCTAssertFalse(first.terminated, "a pinned dir: has a fixed identity — persist:dir can never re-anchor")
        let all = floatSurfaces(spawned(), command: "notes")
        XCTAssertEqual(all.count, 1, "reopen must reuse, not respawn, despite the pane's cwd moving")
        XCTAssertEqual(all[0].startCount, 1, "the retained surface must not be restarted")
        XCTAssertEqual(all[0].lastConfig?.workingDirectory, pinned)
    }

    // MARK: git guard checks where the float runs, not the focused pane

    /// The guard in `toggleToolFloat` must check `floatCWD(spec)` — where the tool actually runs —
    /// not the focused pane's raw cwd. A `dir:`-pinned float into a repo must open even though the
    /// pane itself sits outside any repo.
    func test_gitGuard_opensWhenPinnedDirIsARepo_evenIfPaneCWDIsNot() throws {
        let paneDir = try makeDir("plain", git: false)
        let repoDir = try makeDir("repo", git: true)
        let (controller, spawned) = makeController(cwd: paneDir)
        let float = spec("gitdash", persist: .ephemeral, git: true, dir: repoDir)

        controller.toggleToolFloat(float)

        XCTAssertEqual(
            floatSurfaces(spawned(), command: "gitdash").count, 1,
            "the git guard must check floatCWD (the pinned dir:), not the focused pane's raw cwd")
    }

    /// The inverse: a float pinned to a non-repo directory must be BLOCKED even though the focused
    /// pane itself happens to sit inside a real repo — the guard exists to protect where the tool
    /// runs, not where the pane is.
    func test_gitGuard_blocksWhenPinnedDirIsNotARepo_evenIfPaneCWDIs() throws {
        let repoDir = try makeDir("repo", git: true)
        let plainDir = try makeDir("plain", git: false)
        let (controller, spawned) = makeController(cwd: repoDir)
        let float = spec("gitdash", persist: .ephemeral, git: true, dir: plainDir)

        controller.toggleToolFloat(float)

        XCTAssertTrue(
            floatSurfaces(spawned(), command: "gitdash").isEmpty,
            "a float pinned to a non-repo dir: must be blocked even though the pane sits in a real repo")
    }

    // MARK: config-reload reconciliation (review findings on the shipped registry)

    func test_pruneToolFloats_terminatesADeletedHiddenFloat_andKeepsSurvivors() throws {
        let dir = try makeDir("plain", git: false)
        let (controller, spawned) = makeController(cwd: dir)
        let doomed = spec("dev", persist: .directory)
        let kept = spec("mon", persist: .directory)

        controller.toggleToolFloat(doomed)
        controller.closeToolFloat()
        controller.toggleToolFloat(kept)
        controller.closeToolFloat()
        let doomedSurface = floatSurfaces(spawned(), command: "dev")[0]
        let keptSurface = floatSurfaces(spawned(), command: "mon")[0]

        controller.pruneToolFloats(against: [kept])  // "dev" was deleted in Settings

        XCTAssertTrue(
            doomedSurface.terminated,
            "a deleted float's hidden process has no control left that can reach it — it must die now")
        XCTAssertFalse(keptSurface.terminated, "a float still in the catalog keeps its instance")
    }

    func test_pruneToolFloats_closesAndTerminatesTheShownFloat_whenItWasDeleted() throws {
        let dir = try makeDir("plain", git: false)
        let (controller, spawned) = makeController(cwd: dir)
        let float = spec("dev", persist: .directory)

        controller.toggleToolFloat(float)
        let surface = floatSurfaces(spawned(), command: "dev")[0]

        controller.pruneToolFloats(against: [])

        XCTAssertFalse(controller.isToolFloatOpen, "the card has no toggle left — close it too")
        XCTAssertTrue(surface.terminated)
    }

    func test_editedCommand_respawnsInsteadOfReusingTheOldProcess() throws {
        let dir = try makeDir("plain", git: false)
        let (controller, spawned) = makeController(cwd: dir)

        controller.toggleToolFloat(spec("mon", persist: .directory, command: "btop"))
        let old = floatSurfaces(spawned(), command: "btop")[0]
        controller.closeToolFloat()

        controller.toggleToolFloat(spec("mon", persist: .directory, command: "htop"))  // Settings edit

        XCTAssertTrue(old.terminated, "the instance still running the OLD command must be discarded")
        XCTAssertEqual(
            floatSurfaces(spawned(), command: "htop").count, 1,
            "the edited command must actually launch — reuse here makes the Settings edit a no-op")
    }

    func test_fastFloatSwitchXYX_snapsTheDisplacedCard_beforeRehostingItsView() throws {
        let dir = try makeDir("plain", git: false)
        let (controller, spawned) = makeController(cwd: dir)
        let xSpec = spec("xtool", persist: .directory)
        let ySpec = spec("ytool", persist: .directory)

        controller.toggleToolFloat(xSpec)
        let xSurface = floatSurfaces(spawned(), command: "xtool")[0]
        guard let xFirstCard = xSurface.view.superview?.superview as? SurfaceFloatOverlay else {
            return XCTFail("expected X's view hosted inside a float card")
        }

        controller.toggleToolFloat(ySpec)  // parks X's card, opens Y
        controller.toggleToolFloat(xSpec)  // parks Y (displacing X's parked card), reopens X

        XCTAssertNil(
            xFirstCard.superview,
            "the displaced parked card must be snapped away — while attached it still holds Auto "
                + "Layout constraints on X's shared view, which is being re-hosted into a new card")
        XCTAssertNotNil(xSurface.view.window, "X's view must be live inside the NEW card")
        XCTAssertFalse(
            xSurface.view.isDescendant(of: xFirstCard), "the re-host must land in the new card, not the old")
    }

    func test_hasBusyToolFloat_seesAHiddenBusyFloat() throws {
        let dir = try makeDir("plain", git: false)
        let (controller, spawned) = makeController(cwd: dir)

        controller.toggleToolFloat(spec("dev", persist: .directory))
        let surface = floatSurfaces(spawned(), command: "dev")[0]
        controller.closeToolFloat()

        XCTAssertFalse(controller.hasBusyToolFloat)
        surface.isBusy = true  // e.g. a build watcher doing live work while dismissed
        XCTAssertTrue(
            controller.hasBusyToolFloat,
            "the ⌘W confirm reads this — a hidden busy float is invisible, so this flag is the only "
                + "thing standing between close and silently killing its work")
    }

    func test_gitGuardToast_namesThePinnedDir_notTheFocusedPane() throws {
        let repo = try makeDir("repo", git: true)
        let notes = try makeDir("notes", git: false)
        let (controller, spawned) = makeController(cwd: repo)
        var toasts: [ToastContent] = []
        controller.onRequestToast = { toasts.append($0) }

        controller.toggleToolFloat(spec("gitdash", persist: .directory, git: true, dir: notes))

        XCTAssertTrue(floatSurfaces(spawned(), command: "gitdash").isEmpty)
        XCTAssertEqual(toasts.count, 1)
        XCTAssertTrue(
            toasts[0].message.contains(PathDisplay.abbreviatingHome(notes.path)),
            "the guard evaluated the PINNED dir, so the toast must name it — \"run `git init` here\" "
                + "points at the focused pane, which is a repo and irrelevant: \(toasts[0].message)")
    }
}
