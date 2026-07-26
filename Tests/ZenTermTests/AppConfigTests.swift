import XCTest

@testable import ZenTerm

final class AppConfigTests: XCTestCase {
    /// `loadAtLaunch()` is the only thing that resolves the config statics off disk — neither is
    /// lazy any more (ZEN-31), so dropping the call, or running it after the first window builds,
    /// leaves the whole app on built-in defaults while still compiling and running. Nothing else
    /// would notice. Asserting the font specifically also pins the *order*: `Theme` reads the
    /// general config's font, so resolving the theme first would leave it on the built-in one.
    func test_loadAtLaunch_resolvesBothStaticsFromDisk_generalFirst() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenterm-launch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "font-family = Menlo\n"
            .write(to: root.appendingPathComponent("config"), atomically: true, encoding: .utf8)

        let originalConfig = GeneralConfig.current
        let originalTheme = Theme.current
        ConfigLoader.defaultRootOverrideForTesting = root
        addTeardownBlock {
            ConfigLoader.defaultRootOverrideForTesting = nil
            GeneralConfig.setCurrentForTesting(originalConfig)
            Theme.setCurrentForTesting(originalTheme)
            try? FileManager.default.removeItem(at: root)
        }
        GeneralConfig.setCurrentForTesting(.builtIn)
        Theme.setCurrentForTesting(Theme.builtIn)

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
