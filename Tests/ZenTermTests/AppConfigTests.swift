import XCTest

@testable import ZenTerm

/// The save→reload→apply seam. `AppConfig` is what `.reloadConfig` (⌘⌥R) and every in-app config
/// write route through: it re-resolves the config statics and broadcasts `.configDidChange` so every
/// live observer (keymap, motion, backdrop tint, terminal surfaces) re-applies.
///
/// The thread contract is the part that can be silently dead (ZEN-17): file I/O on the queue, every
/// parse on main. Work that quietly moved back onto the main thread looks identical on a local disk
/// and only shows up as a beachball on the network-backed home this exists for, so these assert
/// where the work runs rather than only what it produces.
///
/// **A green suite is not evidence for the other direction.** Moving the parse OFF main kills a real
/// GUI app (Carbon TIS, see `ConfigLoader.parseGeneralConfig`) while every test here still passes —
/// that shipped once. `ConfigLoader` traps on it now; the real check is `swift run ZenTerm`.
final class AppConfigTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenterm-appconfig-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        ConfigLoader.defaultRootOverrideForTesting = tempRoot
        AppConfig.reloadBlocking()
    }

    override func tearDownWithError() throws {
        drainConfigWrites()  // a write still in flight would land in the real config root
        ConfigLoader.defaultRootOverrideForTesting = nil
        AppConfig.reloadBlocking()
        try? FileManager.default.removeItem(at: tempRoot)
        try super.tearDownWithError()
    }

    private func configText() -> String {
        (try? String(contentsOf: tempRoot.appendingPathComponent("config"), encoding: .utf8)) ?? ""
    }

    func test_reload_postsConfigDidChange() {
        let posted = expectation(forNotification: .configDidChange, object: nil, handler: nil)
        AppConfig.reloadBlocking()
        wait(for: [posted], timeout: 1)
    }

    // MARK: thread contract (ZEN-17)

    /// The whole point: a `ConfigWriter` read-modify-rewrite must not run on the main queue. Settings
    /// live-apply fires one of these every ~180ms while a control settles.
    func test_persist_runsTheWriteOffTheMainThread() {
        let ranOnMain = Locked(true)
        let landed = expectation(description: "write landed")
        AppConfig.persist({ ranOnMain.value = Thread.isMainThread }) { _ in landed.fulfill() }
        wait(for: [landed], timeout: 2)
        XCTAssertFalse(ranOnMain.value, "the config write must not run on the main queue")
    }

    /// The other half of the contract, and the reason `GeneralConfig.adopt` / `Theme.adopt` take a
    /// value instead of reading the file: the statics are chrome state that every view reads from
    /// the main thread, so the resolve goes off-main but the swap and the broadcast come back.
    func test_persist_appliesAndBroadcastsOnTheMainThread() {
        let notifiedOnMain = Locked(false)
        let observer = NotificationCenter.default.addObserver(
            forName: .configDidChange, object: nil, queue: nil
        ) { _ in notifiedOnMain.value = Thread.isMainThread }
        defer { NotificationCenter.default.removeObserver(observer) }

        let completedOnMain = Locked(false)
        let landed = expectation(description: "write landed")
        AppConfig.persist({ try ConfigWriter.apply(scalars: ["font-size": "17"]) }) { _ in
            completedOnMain.value = Thread.isMainThread
            landed.fulfill()
        }
        wait(for: [landed], timeout: 2)

        XCTAssertTrue(completedOnMain.value, "the completion must land on main")
        XCTAssertTrue(notifiedOnMain.value, "configDidChange must be posted on main")
        XCTAssertEqual(GeneralConfig.current.fontSize, 17, "and the statics mirror the file by then")
    }

    /// Two writes must not overlap. Each is a whole-file read-modify-rewrite, so a pair running
    /// concurrently would both read the pre-edit file and the second would erase the first — which
    /// is exactly what a slider settling into two writes would do. The main thread used to provide
    /// this ordering for free; the serial queue is what replaces it.
    func test_persist_serializesOverlappingWrites() {
        let order = Locked([String]())
        let first = expectation(description: "first landed")
        let second = expectation(description: "second landed")

        AppConfig.persist({
            order.mutate { $0.append("first-write") }
            try ConfigWriter.apply(scalars: ["font-size": "20"])
        }) { _ in
            order.mutate { $0.append("first-done") }
            first.fulfill()
        }
        AppConfig.persist({
            order.mutate { $0.append("second-write") }
            try ConfigWriter.apply(scalars: ["cursor-thickness": "3"])
        }) { _ in
            order.mutate { $0.append("second-done") }
            second.fulfill()
        }
        wait(for: [first, second], timeout: 2, enforceOrder: true)

        XCTAssertEqual(
            order.value, ["first-write", "second-write", "first-done", "second-done"],
            "the second write must not start before the first finished")
        let text = configText()
        XCTAssertTrue(text.contains("font-size = 20"), "the first write survives the second: \(text)")
        XCTAssertTrue(text.contains("cursor-thickness = 3"), "and the second landed too: \(text)")
    }

    /// A write that threw changed nothing on disk, so re-resolving and broadcasting would announce a
    /// change that didn't happen — every observer would re-apply, and the Settings row would clear
    /// the error it was just told to show.
    func test_failedWrite_reportsTheErrorAndBroadcastsNothing() {
        var postCount = 0
        let observer = NotificationCenter.default.addObserver(
            forName: .configDidChange, object: nil, queue: .main
        ) { _ in postCount += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }

        struct WriteFailure: Error {}
        let reported = Locked<Error?>(nil)
        let landed = expectation(description: "failure landed")
        AppConfig.persist({ throw WriteFailure() }) { error in
            reported.value = error
            landed.fulfill()
        }
        wait(for: [landed], timeout: 2)

        XCTAssertTrue(reported.value is WriteFailure, "the completion carries the write's error")
        XCTAssertEqual(postCount, 0, "a failed write must not broadcast a config change")
    }

    /// The reads are the half that must be off main: they are the unbounded part on a network or
    /// cloud-synced home, and they are what the split in `ConfigLoader` exists to make movable.
    func test_theFileReadsAreSafeOffTheMainThread() throws {
        try "font-size = 15\ntheme = nord\n".write(
            to: tempRoot.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        let root = tempRoot!
        let done = expectation(description: "read off main")
        DispatchQueue.global(qos: .userInitiated).async {
            let text = ConfigLoader.readGeneralConfigText(configRoot: root)
            XCTAssertTrue(text?.contains("font-size = 15") == true)
            _ = ConfigLoader.readThemeText(configRoot: root, general: .builtIn)
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
    }

    /// A minimal box for a value written on the config queue and read on the main thread once the
    /// expectation has landed. The handoff is ordered by the wait, but the compiler can't see that.
    private final class Locked<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Value
        init(_ value: Value) { stored = value }
        var value: Value {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
        func mutate(_ change: (inout Value) -> Void) { lock.withLock { change(&stored) } }
    }
}
