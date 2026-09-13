import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

final class ToolFloatControllerTests: WindowTestCase {
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

    private func makeDir(_ name: String, git: Bool) throws -> URL {
        let dir = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if git {
            try FileManager.default.createDirectory(
                at: dir.appendingPathComponent(".git", isDirectory: true), withIntermediateDirectories: true)
        }
        return dir
    }

    private func makeFloats(
        cwd: URL, onProbe: (() -> Void)? = nil,
        resolveRepoRoot: ((URL?, @escaping (URL?) -> Void) -> Void)? = nil
    ) -> (
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
            resolveRepoRoot: resolveRepoRoot ?? { cwd, deliver in
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

    private func floatSurfaces(_ spawned: [RecordingSurface], command: String) -> [RecordingSurface] {
        spawned.filter { $0.lastConfig?.args == ["-l", "-i", "-c", command] }
    }

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

        setCWD(repoB)
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
        setCWD(sub)
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
        floats.surfaceDidExit(first, code: 0)

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
        floats.surfaceDidExit(first, code: 0)

        floats.toggle(float)
        XCTAssertEqual(floatSurfaces(spawned(), command: "lazygit").count, 2)
    }

    func test_persistentFloat_reopenBeforeDismissAnimationCompletes_rehostsView_dropsOldCard() throws {
        Motion.isReduceMotionEnabled = { false }
        let dir = try makeDir("plain", git: false)
        let (floats, spawned, setCWD) = makeFloats(cwd: dir)
        let float = spec("btop", persist: .directory)

        floats.toggle(float)
        let surface = floatSurfaces(spawned(), command: "btop")[0]
        let oldOverlay = surface.view.superview?.superview
        XCTAssertNotNil(oldOverlay, "the surface's view must be hosted inside a float card")

        floats.close()
        floats.toggle(float)

        let newOverlay = surface.view.superview?.superview
        XCTAssertNotNil(newOverlay?.superview, "the view must be re-hosted in a card that's actually on screen")
        XCTAssertTrue(oldOverlay !== newOverlay, "reopening must build a new card, not reuse the dismissing one")
        XCTAssertNil(oldOverlay?.superview, "the old dismissing card must be detached, not left dangling on screen")
    }

    func test_persistentFloat_dismissUnderReduceMotion_doesNotStrandTheOverlay() throws {
        Motion.isReduceMotionEnabled = { true }
        let dir = try makeDir("plain", git: false)
        let (floats, spawned, setCWD) = makeFloats(cwd: dir)
        let float = spec("btop", persist: .directory)

        weak var weakOverlay: SurfaceFloatOverlay?
        autoreleasepool {
            floats.toggle(float)
            let surface = floatSurfaces(spawned(), command: "btop")[0]
            weakOverlay = surface.view.superview?.superview as? SurfaceFloatOverlay
            XCTAssertNotNil(weakOverlay, "the surface's view must be hosted inside a float card")

            floats.close()
        }

        XCTAssertNil(
            weakOverlay,
            "a synchronously-completed dismiss must drop every strong ref to the card — a stray "
                + "`dismissingFloatOverlay` assignment after the fact would strand it")

        floats.toggle(float)
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

    func test_dirField_pinnedAnchor_neverReanchorsOnCWDChange() throws {
        let paneDir = try makeDir("pane", git: false)
        let pinned = try makeDir("notes", git: false)
        let elsewhere = try makeDir("elsewhere", git: false)
        let (floats, spawned, setCWD) = makeFloats(cwd: paneDir)
        let float = spec("notes", persist: .directory, dir: pinned)

        floats.toggle(float)
        let first = floatSurfaces(spawned(), command: "notes")[0]
        floats.close()

        setCWD(elsewhere)
        floats.toggle(float)

        XCTAssertFalse(first.terminated, "a pinned dir: has a fixed identity — persist:dir can never re-anchor")
        let all = floatSurfaces(spawned(), command: "notes")
        XCTAssertEqual(all.count, 1, "reopen must reuse, not respawn, despite the pane's cwd moving")
        XCTAssertEqual(all[0].startCount, 1, "the retained surface must not be restarted")
        XCTAssertEqual(all[0].lastConfig?.workingDirectory, pinned)
    }

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

    private func makeHeldProbeFloats(cwd: URL) -> (
        floats: ToolFloatController, spawned: () -> [RecordingSurface], setCWD: (URL) -> Void,
        deliver: () -> Void
    ) {
        var held: [(cwd: URL?, deliver: (URL?) -> Void)] = []
        let (floats, spawned, setCWD) = makeFloats(
            cwd: cwd, resolveRepoRoot: { cwd, deliver in held.append((cwd, deliver)) })
        return (
            floats, spawned, setCWD,
            {
                let pending = held
                held = []
                for probe in pending { probe.deliver(GitRepo.repoRoot(for: probe.cwd)) }
            }
        )
    }

    func test_closeDuringTheProbe_callsTheOpenOff() throws {
        let repo = try makeDir("repo", git: true)
        let (floats, spawned, _, deliver) = makeHeldProbeFloats(cwd: repo)

        floats.toggle(spec("lazygit", persist: .directory))
        floats.close()
        deliver()

        XCTAssertTrue(
            floatSurfaces(spawned(), command: "lazygit").isEmpty,
            "a float closed while it was still probing must not open when the probe lands")
        XCTAssertFalse(floats.isOpen)
    }

    func test_shutdownDuringTheProbe_callsTheOpenOff() throws {
        let repo = try makeDir("repo", git: true)
        let (floats, spawned, _, deliver) = makeHeldProbeFloats(cwd: repo)

        floats.toggle(spec("lazygit", persist: .directory))
        floats.shutdown()
        deliver()

        XCTAssertTrue(
            floatSurfaces(spawned(), command: "lazygit").isEmpty,
            "the window is gone; nothing may spawn into it")
    }

    func test_cancelPendingOpen_stopsTheCardFromLanding() throws {
        let repo = try makeDir("repo", git: true)
        let (floats, spawned, _, deliver) = makeHeldProbeFloats(cwd: repo)

        floats.toggle(spec("lazygit", persist: .directory))
        floats.cancelPendingOpen()
        deliver()

        XCTAssertTrue(floatSurfaces(spawned(), command: "lazygit").isEmpty)
        XCTAssertFalse(floats.isOpen)
    }

    func test_secondPressDuringTheProbe_cancelsInsteadOfOpening() throws {
        let repo = try makeDir("repo", git: true)
        let (floats, spawned, _, deliver) = makeHeldProbeFloats(cwd: repo)
        let float = spec("lazygit", persist: .directory)

        floats.toggle(float)
        floats.toggle(float)
        deliver()

        XCTAssertTrue(
            floatSurfaces(spawned(), command: "lazygit").isEmpty,
            "press-press is open-then-close, not open-then-open")
        XCTAssertFalse(floats.isOpen)
    }

    func test_pendingOpenForAFloatDeletedByAConfigReload_isCancelled() throws {
        let repo = try makeDir("repo", git: true)
        let (floats, spawned, _, deliver) = makeHeldProbeFloats(cwd: repo)

        floats.toggle(spec("lazygit", persist: .directory))
        floats.prune(against: [])
        deliver()

        XCTAssertTrue(
            floatSurfaces(spawned(), command: "lazygit").isEmpty,
            "a float with no config entry left has no card to open")
    }

    func test_directoryFloat_spawnsAtThePressTimeCWD_whenThePaneMovesDuringTheProbe() throws {
        let repoA = try makeDir("a", git: true)
        let repoB = try makeDir("b", git: true)
        let (floats, spawned, setCWD, deliver) = makeHeldProbeFloats(cwd: repoA)

        floats.toggle(spec("lazygit", persist: .directory))
        setCWD(repoB)
        deliver()

        let opened = floatSurfaces(spawned(), command: "lazygit")
        XCTAssertEqual(opened.count, 1)
        XCTAssertEqual(
            opened[0].lastConfig?.workingDirectory, repoA,
            "the shell must start where the anchor was resolved, not wherever the pane ended up")
    }

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

        floats.prune(against: [kept])

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

        floats.toggle(spec("mon", persist: .directory, command: "htop"))

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

        floats.toggle(ySpec)
        floats.toggle(xSpec)

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
        surface.isBusy = true
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

    func test_isLiveInBackground_trueOnlyWhileLiveAndHidden() throws {
        let dir = try makeDir("plain", git: false)
        let (floats, _, _) = makeFloats(cwd: dir)
        let float = spec("btop", persist: .window)

        XCTAssertFalse(floats.isLiveInBackground("btop"), "never launched → nothing to dot")

        floats.toggle(float)
        XCTAssertFalse(floats.isLiveInBackground("btop"), "the float on screen is not 'in background'")

        floats.close()
        XCTAssertTrue(floats.isLiveInBackground("btop"), "live but dismissed → dot it")

        floats.toggle(float)
        XCTAssertFalse(floats.isLiveInBackground("btop"))
    }

    func test_isBusy_tracksTheSurface_notMereLiveness() throws {
        let dir = try makeDir("plain", git: false)
        let (floats, spawned, _) = makeFloats(cwd: dir)
        let float = spec("btop", persist: .window)

        XCTAssertFalse(floats.isBusy("btop"), "never launched → no surface to ask")

        floats.toggle(float)
        let surface = try XCTUnwrap(floatSurfaces(spawned(), command: "btop").first)
        XCTAssertFalse(floats.isBusy("btop"), "shown, but sitting at a prompt")

        surface.isBusy = true
        floats.close()
        XCTAssertTrue(floats.isBusy("btop"), "dismissed and working is the whole point")

        surface.isBusy = false
        XCTAssertFalse(floats.isBusy("btop"), "the work ended")
        XCTAssertTrue(floats.isLiveInBackground("btop"), "while liveness still says yes")
    }

    func test_isLiveInBackground_ephemeralFloat_neverDots() throws {
        let dir = try makeDir("plain", git: false)
        let (floats, _, _) = makeFloats(cwd: dir)
        let float = spec("yazi", persist: .ephemeral)

        floats.toggle(float)
        floats.close()

        XCTAssertFalse(floats.isLiveInBackground("yazi"))
    }

    func test_hiddenFloatExits_clearsLiveInBackground_andNotifies() throws {
        let dir = try makeDir("plain", git: false)
        let (floats, spawned, _) = makeFloats(cwd: dir)
        var stateChanges = 0
        floats.toggle(spec("btop", persist: .window))
        floats.close()
        XCTAssertTrue(floats.isLiveInBackground("btop"))
        floats.onStateChanged = { stateChanges += 1 }

        let surface = try XCTUnwrap(floatSurfaces(spawned(), command: "btop").first)
        surface.delegate?.surfaceDidExit(surface, code: 0)

        XCTAssertFalse(floats.isLiveInBackground("btop"), "the tool exited — nothing left to dot")
        XCTAssertEqual(stateChanges, 1, "the dock must be told, or the dot outlives the process")
    }

    func test_prune_clearsLiveInBackground_andNotifies() throws {
        let dir = try makeDir("plain", git: false)
        let (floats, _, _) = makeFloats(cwd: dir)
        var stateChanges = 0
        floats.toggle(spec("btop", persist: .window))
        floats.close()
        floats.onStateChanged = { stateChanges += 1 }

        floats.prune(against: [])

        XCTAssertFalse(floats.isLiveInBackground("btop"))
        XCTAssertEqual(stateChanges, 1)
    }

    func test_toggle_resolvesRepoRootOffMain() throws {
        let repo = try makeDir("repo", git: true)
        let (floats, spawned, _) = makeFloats(cwd: repo)
        var pending: [(URL?) -> Void] = []
        floats.resolveRepoRoot = { _, completion in pending.append(completion) }
        let float = spec("lazygit", persist: .directory)

        floats.toggle(float)
        XCTAssertFalse(floats.isOpen, "toggle must not open synchronously — the resolve is off-main")
        XCTAssertEqual(pending.count, 1)

        pending[0](repo)
        XCTAssertTrue(floats.isOpen, "the float opens once the root resolves")
        XCTAssertEqual(
            floatSurfaces(spawned(), command: "lazygit").count, 1, "exactly one float, not two")
    }
}
