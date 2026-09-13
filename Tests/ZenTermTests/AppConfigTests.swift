import XCTest

@testable import ZenTerm

final class AppConfigTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenterm-appconfig-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        originalConfig = GeneralConfig.current
        originalTheme = Theme.current
        originalFontSize = SessionFontSize.points
        ConfigLoader.defaultRootOverrideForTesting = root
        GeneralConfig.setCurrentForTesting(.builtIn)
        Theme.setCurrentForTesting(Theme.builtIn)
    }

    override func tearDown() {
        ConfigLoader.defaultRootOverrideForTesting = nil
        GeneralConfig.setCurrentForTesting(originalConfig)
        Theme.setCurrentForTesting(originalTheme)
        var seed = GeneralConfig.builtIn
        seed.fontSize = originalFontSize
        SessionFontSize.seed(from: seed)
        try? FileManager.default.removeItem(at: root)
        root = nil
        super.tearDown()
    }

    private var originalConfig = GeneralConfig.builtIn
    private var originalTheme = Theme.builtIn
    private var originalFontSize = GeneralConfig.builtIn.fontSize

    func test_loadAtLaunch_resolvesBothStaticsFromDisk_generalFirst() throws {
        try "font-family = Menlo\n"
            .write(to: root.appendingPathComponent("config"), atomically: true, encoding: .utf8)

        AppConfig.loadAtLaunch()

        XCTAssertEqual(GeneralConfig.current.fontName, "Menlo", "the general config never resolved")
        XCTAssertEqual(
            Theme.current.terminal.fontName, "Menlo",
            "the theme resolved before the general config, so it took the built-in font")
    }

    func test_loadAtLaunch_seedsTheSessionFontSize() throws {
        let stepped = GeneralConfig.builtIn.fontSize + 3
        try "font-size = \(Int(stepped))\n"
            .write(to: root.appendingPathComponent("config"), atomically: true, encoding: .utf8)

        AppConfig.loadAtLaunch()

        XCTAssertEqual(
            SessionFontSize.points, stepped,
            "the first pane opens at the built-in size rather than the configured one")
    }

    func test_reload_postsConfigDidChange() {
        let expectation = expectation(forNotification: .configDidChange, object: nil, handler: nil)
        AppConfig.reload()
        wait(for: [expectation], timeout: 1)
    }

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

    func test_unforcedReloadOfUnchangedConfig_broadcastsNothing() {
        AppConfig.reload()

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
