import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

/// Lifecycle tests for the tool-float engine (ZEN-77, lifted to window scope in ZEN-141): drive
/// `toggle` on a window-mounted `ToolFloatController` and assert what the `persist:` mode does to
/// the underlying surface. Asserts through the real spawn/terminate path
/// (`RecordingSurface.startCount` / `.terminated`) rather than the registry, because a state-only
/// test would pass while the surface was actually being killed. The window-scope claims the engine
/// exists for — one instance across two tabs, a card that rides a tab switch — need real tabs and
/// live in `WindowControllerToolFloatTests`.
final class ToolFloatControllerTests: XCTestCase {
    private var windows: [NSWindow] = []
    private var floatControllers: [ToolFloatController] = []
    private var root = FileManager.default.temporaryDirectory

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenterm-floats-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        floatControllers.forEach { $0.shutdown() }
        floatControllers = []
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

    /// A window-mounted float engine over `cwd`, recording every surface it spawns.
    ///
    /// Hosts cards in a real view tree (the re-host and snap-away assertions walk
    /// `surface.view.superview`, and `animateIn` lays out against a live window), and reaches the
    /// "focused pane's cwd" through the same closure seam `WindowController` wires up — so
    /// `setCWD` here stands in for a pane's shell `cd`-ing, which is exactly what the engine sees.
    ///
    /// The repo-root probe is injected synchronously: in the app it runs off the main thread
    /// (ZEN-90/ZEN-15), so a toggle that needs one takes a hop, and every assertion here would have
    /// to become an expectation. `onProbe` fires on each probe, for the tests that care whether one
    /// happened at all. What the async delivery itself does to the open path is a runbook step.
    private func makeFloats(cwd: URL, onProbe: (() -> Void)? = nil) -> (
        floats: ToolFloatController, spawned: () -> [RecordingSurface], setCWD: (URL) -> Void
    ) {
        var spawned: [RecordingSurface] = []
        var currentCWD = cwd
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.borderless], backing: .buffered, defer: false)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        window.contentView?.addSubview(host)
        let floats = ToolFloatController(
            presentOverlay: { overlay in
                overlay.translatesAutoresizingMaskIntoConstraints = false
                host.addSubview(overlay)
                NSLayoutConstraint.activate([
                    overlay.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                    overlay.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                    overlay.topAnchor.constraint(equalTo: host.topAnchor),
                    overlay.bottomAnchor.constraint(equalTo: host.bottomAnchor),
                ])
            },
            focusedCWD: { currentCWD },
            yieldFocus: {},
            restoreFocus: {},
            makeSurface: {
                let surface = RecordingSurface()
                spawned.append(surface)
                return surface
            },
            resolveRepoRoot: { cwd, deliver in
                onProbe?()
                deliver(GitRepo.repoRoot(for: cwd))
            })
        host.layoutSubtreeIfNeeded()
        windows.append(window)
        floatControllers.append(floats)
        return (floats, { spawned }, { currentCWD = $0 })
    }

    private func spec(
        _ id: String, persist: ToolFloat.Persistence, git: Bool = false, dir: URL? = nil,
        command: String? = nil
    ) -> ToolFloat {
        ToolFloat(
            id: id, order: 0, title: id, icon: ToolFloatParser.defaultIcon, command: command ?? id,
            dir: dir, widthFraction: 0.85, heightFraction: 0.85, requiresGitRepo: git,
            persist: persist, toggle: Chord(command: true, shift: true, key: "j"))
    }

    /// The surfaces for one float, filtered by the command its spec launches, so a test driving
    /// two floats can tell them apart.
    private func floatSurfaces(_ spawned: [RecordingSurface], command: String) -> [RecordingSurface] {
        spawned.filter { $0.lastConfig?.args == ["-l", "-i", "-c", command] }
    }

    // MARK: tests

    func test_ephemeralFloat_terminatesOnDismiss() throws {
        let dir = try makeDir("plain", git: false)
        let (floats, spawned, setCWD) = makeFloats(cwd: dir)
        let float = spec("yazi", persist: .ephemeral)

        floats.toggle(float)
        let opened = floatSurfaces(spawned(), command: "yazi")
        XCTAssertEqual(opened.count, 1)

        floats.close()
        XCTAssertTrue(opened[0].terminated, "an ephemeral float must die on dismiss")

        floats.toggle(float)
        XCTAssertEqual(floatSurfaces(spawned(), command: "yazi").count, 2, "reopen spawns fresh")
    }

    func test_dirFloat_survivesDismiss_andReusesSurfaceOnReopen() throws {
        let repo = try makeDir("repo", git: true)
        let (floats, spawned, setCWD) = makeFloats(cwd: repo)
        let float = spec("lazygit", persist: .directory)

        floats.toggle(float)
        let first = floatSurfaces(spawned(), command: "lazygit")
        XCTAssertEqual(first.count, 1)

        floats.close()
        XCTAssertFalse(first[0].terminated, "a persistent float must survive dismiss")

        floats.toggle(float)
        XCTAssertEqual(
            floatSurfaces(spawned(), command: "lazygit").count, 1, "reopen must reuse, not respawn")
        XCTAssertEqual(first[0].startCount, 1, "the retained surface must not be restarted")
    }

    func test_dirFloat_respawnsWhenAnchorChanges() throws {
        let repoA = try makeDir("a", git: true)
        let repoB = try makeDir("b", git: true)
        let (floats, spawned, setCWD) = makeFloats(cwd: repoA)
        let float = spec("lazygit", persist: .directory)

        floats.toggle(float)
        let first = floatSurfaces(spawned(), command: "lazygit")[0]
        floats.close()

        setCWD(repoB)  // the focused pane cd'd to another repo
        floats.toggle(float)

        XCTAssertTrue(first.terminated, "the stale instance must be discarded")
        let all = floatSurfaces(spawned(), command: "lazygit")
        XCTAssertEqual(all.count, 2, "a new repo gets a new instance")
        XCTAssertEqual(all[1].lastConfig?.workingDirectory, repoB)
    }

    func test_dirFloat_anchorsToRepoRoot_soSubdirReusesTheInstance() throws {
        let repo = try makeDir("repo", git: true)
        let sub = repo.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let (floats, spawned, setCWD) = makeFloats(cwd: repo)
        let float = spec("lazygit", persist: .directory)

        floats.toggle(float)
        floats.close()
        setCWD(sub)  // same repo, different subdir
        floats.toggle(float)

        XCTAssertEqual(
            floatSurfaces(spawned(), command: "lazygit").count, 1,
            "cd'ing within one repo must not reload the float")
    }

    func test_dirFloat_outsideARepo_anchorsToThePlainCWD() throws {
        let dirA = try makeDir("plain-a", git: false)
        let dirB = try makeDir("plain-b", git: false)
        let (floats, spawned, setCWD) = makeFloats(cwd: dirA)
        let float = spec("btm", persist: .directory)

        floats.toggle(float)
        floats.close()
        floats.toggle(float)
        XCTAssertEqual(floatSurfaces(spawned(), command: "btm").count, 1, "same dir reuses")

        floats.close()
        setCWD(dirB)
        floats.toggle(float)
        XCTAssertEqual(floatSurfaces(spawned(), command: "btm").count, 2, "a different dir respawns")
    }

    func test_persistentFloat_terminatedOnShutdown() throws {
        let dir = try makeDir("plain", git: false)
        let (floats, spawned, setCWD) = makeFloats(cwd: dir)

        floats.toggle(spec("btop", persist: .directory))
        let surface = floatSurfaces(spawned(), command: "btop")[0]
        floats.close()
        XCTAssertFalse(surface.terminated)

        floats.shutdown()
        XCTAssertTrue(surface.terminated, "a hidden persistent float must not outlive its tab")
    }

    func test_persistentFloat_processExit_clearsRegistry_soNextOpenSpawnsFresh() throws {
        let dir = try makeDir("plain", git: false)
        let (floats, spawned, setCWD) = makeFloats(cwd: dir)
        let float = spec("lazygit", persist: .directory)

        floats.toggle(float)
        let first = floatSurfaces(spawned(), command: "lazygit")[0]
        floats.surfaceDidExit(first, code: 0)  // `q` inside the tool

        floats.toggle(float)
        XCTAssertEqual(
            floatSurfaces(spawned(), command: "lazygit").count, 2,
            "a quit tool must spawn fresh on the next open, not resurrect a dead surface")
    }

    func test_hiddenPersistentFloat_processExit_clearsRegistry() throws {
        let dir = try makeDir("plain", git: false)
        let (floats, spawned, setCWD) = makeFloats(cwd: dir)
        let float = spec("lazygit", persist: .directory)

        floats.toggle(float)
        let first = floatSurfaces(spawned(), command: "lazygit")[0]
        floats.close()
        floats.surfaceDidExit(first, code: 0)  // the tool died while hidden

        floats.toggle(float)
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
        let (floats, spawned, setCWD) = makeFloats(cwd: dir)
        let float = spec("btop", persist: .directory)

        floats.toggle(float)
        let surface = floatSurfaces(spawned(), command: "btop")[0]
        let oldOverlay = surface.view.superview?.superview
        XCTAssertNotNil(oldOverlay, "the surface's view must be hosted inside a float card")

        floats.close()  // a persistent dismiss parks the still-springing-out card
        floats.toggle(float)  // reopen before its exit animation finishes

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
        let (floats, spawned, setCWD) = makeFloats(cwd: dir)
        let float = spec("btop", persist: .directory)

        weak var weakOverlay: SurfaceFloatOverlay?
        // AppKit views are autoreleased, so a weak ref doesn't clear the instant the last strong ref
        // drops — it clears when the pool drains. Do the open/close inside the pool so the assertion
        // measures stranding rather than autorelease timing.
        autoreleasepool {
            floats.toggle(float)
            let surface = floatSurfaces(spawned(), command: "btop")[0]
            weakOverlay = surface.view.superview?.superview as? SurfaceFloatOverlay
            XCTAssertNotNil(weakOverlay, "the surface's view must be hosted inside a float card")

            floats.close()  // Reduce Motion runs `animateOut`'s completion synchronously
        }

        XCTAssertNil(
            weakOverlay,
            "a synchronously-completed dismiss must drop every strong ref to the card — a stray "
                + "`dismissingFloatOverlay` assignment after the fact would strand it")

        floats.toggle(float)  // reopening after must still reuse, not respawn
        XCTAssertEqual(floatSurfaces(spawned(), command: "btop").count, 1)
    }

    func test_dirField_pinsTheSpawnDirectory_ignoringTheFocusedCWD() throws {
        let paneDir = try makeDir("pane", git: false)
        let pinned = try makeDir("notes", git: false)
        let (floats, spawned, setCWD) = makeFloats(cwd: paneDir)

        floats.toggle(spec("notes", persist: .ephemeral, dir: pinned))

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
        let (floats, spawned, setCWD) = makeFloats(cwd: paneDir)
        let float = spec("notes", persist: .directory, dir: pinned)

        floats.toggle(float)
        let first = floatSurfaces(spawned(), command: "notes")[0]
        floats.close()

        setCWD(elsewhere)  // would force a respawn without a pinned dir:
        floats.toggle(float)

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
        let (floats, spawned, setCWD) = makeFloats(cwd: paneDir)
        let float = spec("gitdash", persist: .ephemeral, git: true, dir: repoDir)

        floats.toggle(float)

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
        let (floats, spawned, setCWD) = makeFloats(cwd: repoDir)
        let float = spec("gitdash", persist: .ephemeral, git: true, dir: plainDir)

        floats.toggle(float)

        XCTAssertTrue(
            floatSurfaces(spawned(), command: "gitdash").isEmpty,
            "a float pinned to a non-repo dir: must be blocked even though the pane sits in a real repo")
    }

    /// The repo root feeds exactly two things — the `git:` guard and a `.directory` float's anchor —
    /// so a float wanting neither must open without walking the filesystem at all (ZEN-15). The walk
    /// is a run of stats per ancestor, unbounded on a network mount.
    func test_plainEphemeralFloat_opensWithoutProbingTheFilesystem() throws {
        let dir = try makeDir("plain", git: false)
        var probes = 0
        let (floats, spawned, _) = makeFloats(cwd: dir, onProbe: { probes += 1 })

        floats.toggle(spec("yazi", persist: .ephemeral))

        XCTAssertEqual(floatSurfaces(spawned(), command: "yazi").count, 1, "the float still opens")
        XCTAssertEqual(probes, 0, "nothing needs the repo root, so nothing may walk for it")
    }

    func test_gitGatedFloat_probesForItsGuard() throws {
        let repo = try makeDir("repo", git: true)
        var probes = 0
        let (floats, spawned, _) = makeFloats(cwd: repo, onProbe: { probes += 1 })

        floats.toggle(spec("gitdash", persist: .ephemeral, git: true))

        XCTAssertEqual(floatSurfaces(spawned(), command: "gitdash").count, 1)
        XCTAssertEqual(probes, 1, "one walk per press, shared by the guard and the anchor")
    }

    // MARK: config-reload reconciliation (review findings on the shipped registry)

    func test_pruneToolFloats_terminatesADeletedHiddenFloat_andKeepsSurvivors() throws {
        let dir = try makeDir("plain", git: false)
        let (floats, spawned, setCWD) = makeFloats(cwd: dir)
        let doomed = spec("dev", persist: .directory)
        let kept = spec("mon", persist: .directory)

        floats.toggle(doomed)
        floats.close()
        floats.toggle(kept)
        floats.close()
        let doomedSurface = floatSurfaces(spawned(), command: "dev")[0]
        let keptSurface = floatSurfaces(spawned(), command: "mon")[0]

        floats.prune(against: [kept])  // "dev" was deleted in Settings

        XCTAssertTrue(
            doomedSurface.terminated,
            "a deleted float's hidden process has no control left that can reach it — it must die now")
        XCTAssertFalse(keptSurface.terminated, "a float still in the catalog keeps its instance")
    }

    func test_pruneToolFloats_closesAndTerminatesTheShownFloat_whenItWasDeleted() throws {
        let dir = try makeDir("plain", git: false)
        let (floats, spawned, setCWD) = makeFloats(cwd: dir)
        let float = spec("dev", persist: .directory)

        floats.toggle(float)
        let surface = floatSurfaces(spawned(), command: "dev")[0]

        floats.prune(against: [])

        XCTAssertFalse(floats.isOpen, "the card has no toggle left — close it too")
        XCTAssertTrue(surface.terminated)
    }

    func test_editedCommand_respawnsInsteadOfReusingTheOldProcess() throws {
        let dir = try makeDir("plain", git: false)
        let (floats, spawned, setCWD) = makeFloats(cwd: dir)

        floats.toggle(spec("mon", persist: .directory, command: "btop"))
        let old = floatSurfaces(spawned(), command: "btop")[0]
        floats.close()

        floats.toggle(spec("mon", persist: .directory, command: "htop"))  // Settings edit

        XCTAssertTrue(old.terminated, "the instance still running the OLD command must be discarded")
        XCTAssertEqual(
            floatSurfaces(spawned(), command: "htop").count, 1,
            "the edited command must actually launch — reuse here makes the Settings edit a no-op")
    }

    func test_fastFloatSwitchXYX_snapsTheDisplacedCard_beforeRehostingItsView() throws {
        let dir = try makeDir("plain", git: false)
        let (floats, spawned, setCWD) = makeFloats(cwd: dir)
        let xSpec = spec("xtool", persist: .directory)
        let ySpec = spec("ytool", persist: .directory)

        floats.toggle(xSpec)
        let xSurface = floatSurfaces(spawned(), command: "xtool")[0]
        guard let xFirstCard = xSurface.view.superview?.superview as? SurfaceFloatOverlay else {
            return XCTFail("expected X's view hosted inside a float card")
        }

        floats.toggle(ySpec)  // parks X's card, opens Y
        floats.toggle(xSpec)  // parks Y (displacing X's parked card), reopens X

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
        let (floats, spawned, setCWD) = makeFloats(cwd: dir)

        floats.toggle(spec("dev", persist: .directory))
        let surface = floatSurfaces(spawned(), command: "dev")[0]
        floats.close()

        XCTAssertFalse(floats.hasBusy)
        surface.isBusy = true  // e.g. a build watcher doing live work while dismissed
        XCTAssertTrue(
            floats.hasBusy,
            "the ⌘W confirm reads this — a hidden busy float is invisible, so this flag is the only "
                + "thing standing between close and silently killing its work")
    }

    func test_gitGuardToast_namesThePinnedDir_notTheFocusedPane() throws {
        let repo = try makeDir("repo", git: true)
        let notes = try makeDir("notes", git: false)
        let (floats, spawned, setCWD) = makeFloats(cwd: repo)
        var toasts: [ToastContent] = []
        floats.onRequestToast = { toasts.append($0) }

        floats.toggle(spec("gitdash", persist: .directory, git: true, dir: notes))

        XCTAssertTrue(floatSurfaces(spawned(), command: "gitdash").isEmpty)
        XCTAssertEqual(toasts.count, 1)
        XCTAssertTrue(
            toasts[0].message.contains(PathDisplay.abbreviatingHome(notes.path)),
            "the guard evaluated the PINNED dir, so the toast must name it — \"run `git init` here\" "
                + "points at the focused pane, which is a repo and irrelevant: \(toasts[0].message)")
    }

    // MARK: live-in-background (ZEN-150)

    func test_isLiveInBackground_trueOnlyWhileLiveAndHidden() throws {
        let dir = try makeDir("plain", git: false)
        let (floats, _, _) = makeFloats(cwd: dir)
        let float = spec("btop", persist: .window)

        XCTAssertFalse(floats.isLiveInBackground("btop"), "never launched → nothing to dot")

        floats.toggle(float)  // shown
        XCTAssertFalse(floats.isLiveInBackground("btop"), "the float on screen is not 'in background'")

        floats.close()  // hidden, process still alive
        XCTAssertTrue(floats.isLiveInBackground("btop"), "live but dismissed → dot it")

        floats.toggle(float)  // shown again
        XCTAssertFalse(floats.isLiveInBackground("btop"))
    }

    /// An `.ephemeral` float never enters the registry — its process dies with the card, so there
    /// is no background state to dot.
    func test_isLiveInBackground_ephemeralFloat_neverDots() throws {
        let dir = try makeDir("plain", git: false)
        let (floats, _, _) = makeFloats(cwd: dir)
        let float = spec("yazi", persist: .ephemeral)

        floats.toggle(float)
        floats.close()

        XCTAssertFalse(floats.isLiveInBackground("yazi"))
    }

    /// The stale dot: a hidden float's tool quitting is the one path that ends live-in-background
    /// without the card opening or closing, and it never fired `onStateChanged` — so the dock kept
    /// dotting a tool that had already exited.
    func test_hiddenFloatExits_clearsLiveInBackground_andNotifies() throws {
        let dir = try makeDir("plain", git: false)
        let (floats, spawned, _) = makeFloats(cwd: dir)
        var stateChanges = 0
        floats.toggle(spec("btop", persist: .window))
        floats.close()
        XCTAssertTrue(floats.isLiveInBackground("btop"))
        floats.onStateChanged = { stateChanges += 1 }  // count only the exit

        let surface = try XCTUnwrap(floatSurfaces(spawned(), command: "btop").first)
        surface.delegate?.surfaceDidExit(surface, code: 0)  // the user quit the tool from inside

        XCTAssertFalse(floats.isLiveInBackground("btop"), "the tool exited — nothing left to dot")
        XCTAssertEqual(stateChanges, 1, "the dock must be told, or the dot outlives the process")
    }

    /// A float deleted in Settings is pruned from the registry; the dock must re-render or it keeps
    /// a dot for a float that no longer has a button at all.
    func test_prune_clearsLiveInBackground_andNotifies() throws {
        let dir = try makeDir("plain", git: false)
        let (floats, _, _) = makeFloats(cwd: dir)
        var stateChanges = 0
        floats.toggle(spec("btop", persist: .window))
        floats.close()
        floats.onStateChanged = { stateChanges += 1 }

        floats.prune(against: [])  // the float was deleted in Settings

        XCTAssertFalse(floats.isLiveInBackground("btop"))
        XCTAssertEqual(stateChanges, 1)
    }
}
