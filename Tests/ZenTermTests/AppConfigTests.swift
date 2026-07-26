import XCTest

@testable import ZenTerm

final class AppConfigTests: XCTestCase {
    /// Every test here calls a `ConfigLoader` path, which resolves `ConfigLoader.defaultRoot` — the
    /// real `~/.config/zen-term` unless it's overridden. Sandbox it for the whole class and restore
    /// both statics afterwards: since ZEN-31 they start at `.builtIn`, so a test that left the
    /// developer's own config in `GeneralConfig.current` would hand every class that runs later a
    /// different baseline than CI's (where there is no user config), and the difference only shows
    /// up as a test that passes under `--filter` and fails in the full suite, or the reverse.
    private var root: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenterm-appconfig-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        originalConfig = GeneralConfig.current
        originalTheme = Theme.current
        ConfigLoader.defaultRootOverrideForTesting = root
        GeneralConfig.setCurrentForTesting(.builtIn)
        Theme.setCurrentForTesting(Theme.builtIn)
    }

    override func tearDown() {
        ConfigLoader.defaultRootOverrideForTesting = nil
        GeneralConfig.setCurrentForTesting(originalConfig)
        Theme.setCurrentForTesting(originalTheme)
        try? FileManager.default.removeItem(at: root)
        root = nil
        super.tearDown()
    }

    private var originalConfig = GeneralConfig.builtIn
    private var originalTheme = Theme.builtIn

    /// `loadAtLaunch()` is the only thing that resolves the config statics off disk (ZEN-31), so if
    /// it stops running the app is silently on built-in defaults: built-in theme and font, default
    /// chords, no dock tool floats. Asserting the font specifically also pins the *order*, which is
    /// the half a reader is most likely to "tidy": `Theme` reads the general config's font, so
    /// resolving the theme first leaves it on the built-in one.
    ///
    /// This covers the function, not the single call site in `applicationDidFinishLaunching` —
    /// see ZEN-294.
    func test_loadAtLaunch_resolvesBothStaticsFromDisk_generalFirst() throws {
        try "font-family = Menlo\n"
            .write(to: root.appendingPathComponent("config"), atomically: true, encoding: .utf8)

        AppConfig.loadAtLaunch()

        XCTAssertEqual(GeneralConfig.current.fontName, "Menlo", "the general config never resolved")
        XCTAssertEqual(
            Theme.current.terminal.fontName, "Menlo",
            "the theme resolved before the general config, so it took the built-in font")
    }

    /// `AppConfig.reload()` is the seam `.reloadConfig` routes through (`AppDelegate.route`
    /// calls it directly, app-level, alongside `.newWindow`): it re-resolves the config statics
    /// and broadcasts `.configDidChange` so every live observer (keymap, motion, backdrop tint,
    /// terminal surfaces) re-applies. This asserts the broadcast half of that contract.
    func test_reload_postsConfigDidChange() {
        let expectation = expectation(forNotification: .configDidChange, object: nil, handler: nil)
        AppConfig.reload()
        wait(for: [expectation], timeout: 1)
    }

    /// Every post carries a change set, so an observer never has to fall back to `.all` on the
    /// normal path — the fallback is there for hand-posted notifications, not for `reload()`.
    func test_reload_carriesAChangeSet() {
        var carried: ConfigChange?
        let expectation = expectation(forNotification: .configDidChange, object: nil) { note in
            carried = note.userInfo?[ConfigChange.userInfoKey] as? ConfigChange
            return true
        }
        AppConfig.reload()
        wait(for: [expectation], timeout: 1)
        XCTAssertNotNil(carried, "reload() posted without a change set — every observer would do full work")
    }

    /// ⌘⌥R is the "make the app match my config" escape hatch. Re-reading a file that resolved to
    /// the same values diffs to nothing, so without the force flag the chord would become a no-op
    /// — it has to re-apply everything regardless of the diff.
    func test_forcedReload_broadcastsAll() {
        var carried: ConfigChange?
        let expectation = expectation(forNotification: .configDidChange, object: nil) { note in
            carried = note.userInfo?[ConfigChange.userInfoKey] as? ConfigChange
            return true
        }
        AppConfig.reload(force: true)
        wait(for: [expectation], timeout: 1)
        XCTAssertEqual(carried, .all)
    }

    /// The unforced path must NOT hand out `.all` for a reload that changed nothing, or the gate
    /// buys nothing on the Settings live-apply path it exists for.
    func test_unforcedReloadOfUnchangedConfig_broadcastsNothing() {
        AppConfig.reload()  // settle: `current` now matches the file

        var carried: ConfigChange?
        let expectation = expectation(forNotification: .configDidChange, object: nil) { note in
            carried = note.userInfo?[ConfigChange.userInfoKey] as? ConfigChange
            return true
        }
        AppConfig.reload()
        wait(for: [expectation], timeout: 1)
        XCTAssertEqual(carried, [], "a no-op reload still asked every observer to re-apply")
    }
}
