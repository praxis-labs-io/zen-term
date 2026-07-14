import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

/// A seam-conforming fake recording what the controller asked of it.
private final class FakeSurface: NSObject, TerminalSurface {
    let view = NSView()
    weak var delegate: TerminalSurfaceDelegate?
    var title = ""
    var isFocused = false
    var lastConfig: TerminalSurfaceConfig?
    var terminated = false
    func start(_ config: TerminalSurfaceConfig) { lastConfig = config }
    func focus() {}
    func terminate() { terminated = true }
    func paste(_ text: String) {}
    func copySelection() -> String? { nil }
    func scrollToBottom() {}
}

/// ZEN-55: the lazygit pre-warm is debounced off the `applyRecipe` spawn turn and
/// capped by the never-opened LRU pool; a `⌘G`-opened surface is promoted and never
/// evicted. Window-mounted per the house rule.
final class TabControllerLazygitTests: XCTestCase {
    private static let lazygitArgs = ["-l", "-i", "-c", "lazygit"]

    private var root: URL!
    private var windows: [NSWindow] = []
    private var controllers: [TabController] = []

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("zen-lazygit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for controller in controllers { controller.shutdown() }
        controllers = []
        windows = []
        try? FileManager.default.removeItem(at: root)
    }

    private func makeDir(_ name: String, git: Bool) throws -> URL {
        let dir = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if git {
            try FileManager.default.createDirectory(
                at: dir.appendingPathComponent(".git", isDirectory: true),
                withIntermediateDirectories: true)
        }
        return dir
    }

    /// A window-mounted controller over `cwd`, recording every surface it spawns.
    private func makeController(
        cwd: URL, pool: LazygitPrewarmPool
    ) -> (controller: TabController, spawned: () -> [FakeSurface]) {
        var spawned: [FakeSurface] = []
        let controller = TabController(
            initialCWD: cwd,
            makeSurface: {
                let surface = FakeSurface()
                spawned.append(surface)
                return surface
            })
        controller.prewarmPool = pool
        controller.pinnedTitle = "repo"  // workspace tabs (the only pre-warm path) are pinned
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.borderless], backing: .buffered, defer: false)
        controller.view.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        window.contentView?.addSubview(controller.view)
        controller.view.layoutSubtreeIfNeeded()
        windows.append(window)
        controllers.append(controller)
        return (controller, { spawned })
    }

    private func lazygitSurfaces(in spawned: [FakeSurface]) -> [FakeSurface] {
        spawned.filter { $0.lastConfig?.args == Self.lazygitArgs }
    }

    private func recipe(at path: URL) -> Workspace {
        Workspace(
            title: "repo", path: path, main: nil, right: nil, bottom: nil, focus: .main, env: [:])
    }

    /// Drain the main queue past the debounce deadline so pending pre-warm items fire.
    private func drainMainQueue(for interval: TimeInterval) {
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.asyncAfter(deadline: .now() + interval) { drained.fulfill() }
        wait(for: [drained], timeout: 5)
    }

    func test_applyRecipe_defersLazygitSpawnPastTheOpenTurn() throws {
        let repo = try makeDir("repo", git: true)
        let (controller, spawned) = makeController(cwd: repo, pool: LazygitPrewarmPool(capacity: 3))
        controller.prewarmDelay = 0.05

        controller.applyRecipe(recipe(at: repo))
        XCTAssertTrue(
            lazygitSurfaces(in: spawned()).isEmpty,
            "the open turn must not spawn lazygit — that's the ZEN-55 burst")

        drainMainQueue(for: 0.2)
        let lazygits = lazygitSurfaces(in: spawned())
        XCTAssertEqual(lazygits.count, 1, "the debounced pre-warm spawns exactly one lazygit")
        XCTAssertTrue(controller.prewarmPool.contains(controller), "a pre-warm is admitted to the pool")
    }

    func test_shutdownBeforeDelay_cancelsThePrewarm() throws {
        let repo = try makeDir("repo", git: true)
        let (controller, spawned) = makeController(cwd: repo, pool: LazygitPrewarmPool(capacity: 3))
        controller.prewarmDelay = 0.05

        controller.applyRecipe(recipe(at: repo))
        controller.shutdown()
        drainMainQueue(for: 0.2)

        XCTAssertTrue(
            lazygitSurfaces(in: spawned()).isEmpty,
            "closing the tab mid-debounce must cancel the pending pre-warm")
    }

    func test_toggleBeforeDelay_spawnsOnceAndStaysPromoted() throws {
        let repo = try makeDir("repo", git: true)
        let pool = LazygitPrewarmPool(capacity: 3)
        let (controller, spawned) = makeController(cwd: repo, pool: pool)

        controller.applyRecipe(recipe(at: repo))
        controller.toggleLazygit()  // ⌘G beats the debounce timer
        XCTAssertEqual(lazygitSurfaces(in: spawned()).count, 1)
        XCTAssertFalse(pool.contains(controller), "an opened surface is promoted out of the pool")

        controller.prewarmLazygitNow()  // a late timer firing must not demote it
        XCTAssertEqual(lazygitSurfaces(in: spawned()).count, 1, "the surface is already live")
        XCTAssertFalse(pool.contains(controller))
    }

    func test_admitPastCapacity_evictsOldestAndItRespawnsOnDemand() throws {
        let pool = LazygitPrewarmPool(capacity: 1)
        let firstRepo = try makeDir("first", git: true)
        let secondRepo = try makeDir("second", git: true)
        let (first, firstSpawned) = makeController(cwd: firstRepo, pool: pool)
        let (second, secondSpawned) = makeController(cwd: secondRepo, pool: pool)

        first.prewarmLazygitNow()
        second.prewarmLazygitNow()

        XCTAssertTrue(
            lazygitSurfaces(in: firstSpawned())[0].terminated,
            "past capacity, the oldest never-opened pre-warm is evicted")
        XCTAssertFalse(lazygitSurfaces(in: secondSpawned())[0].terminated)
        XCTAssertFalse(pool.contains(first))

        first.toggleLazygit()  // ⌘G on the evicted tab falls back to spawn-on-demand
        let firstLazygits = lazygitSurfaces(in: firstSpawned())
        XCTAssertEqual(firstLazygits.count, 2)
        XCTAssertFalse(firstLazygits[1].terminated)
    }

    func test_promotedSurface_isNeverEvicted() throws {
        let pool = LazygitPrewarmPool(capacity: 1)
        let repo = try makeDir("repo", git: true)
        let (opened, openedSpawned) = makeController(cwd: repo, pool: pool)
        opened.prewarmLazygitNow()
        opened.toggleLazygit()  // promote

        for name in ["a", "b"] {
            let other = try makeDir(name, git: true)
            let (controller, _) = makeController(cwd: other, pool: pool)
            controller.prewarmLazygitNow()
        }

        XCTAssertFalse(
            lazygitSurfaces(in: openedSpawned())[0].terminated,
            "filling the pool must never evict a surface the user opened")
    }

    func test_nonRepoCWD_neitherSpawnsNorAdmits() throws {
        let plain = try makeDir("plain", git: false)
        let pool = LazygitPrewarmPool(capacity: 3)
        let (controller, spawned) = makeController(cwd: plain, pool: pool)

        controller.prewarmLazygitNow()

        XCTAssertTrue(lazygitSurfaces(in: spawned()).isEmpty, "lazygit is useless off-repo")
        XCTAssertFalse(pool.contains(controller))
        XCTAssertEqual(pool.count, 0)
    }

    func test_visibleQuitRewarm_staysPromoted() throws {
        let pool = LazygitPrewarmPool(capacity: 1)
        let repo = try makeDir("repo", git: true)
        let (controller, spawned) = makeController(cwd: repo, pool: pool)
        controller.prewarmLazygitNow()
        controller.toggleLazygit()  // visible → quitting rewarms

        let quit = lazygitSurfaces(in: spawned())[0]
        controller.surfaceDidExit(quit, code: 0)

        let lazygits = lazygitSurfaces(in: spawned())
        XCTAssertEqual(lazygits.count, 2, "a visible quit rewarms a fresh surface")
        XCTAssertFalse(pool.contains(controller), "the rewarmed surface stays promoted")

        let other = try makeDir("other", git: true)
        let (otherController, _) = makeController(cwd: other, pool: pool)
        otherController.prewarmLazygitNow()
        XCTAssertFalse(
            lazygits[1].terminated,
            "filling the pool after a rewarm must not evict the promoted surface")
    }
}
