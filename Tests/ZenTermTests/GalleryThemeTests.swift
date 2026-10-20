import XCTest

@testable import ZenTerm

final class GalleryThemeTests: XCTestCase {
    private var root: URL!
    private var originalConfig = GeneralConfig.builtIn
    private var originalTheme = Theme.builtIn
    private var posted: [ConfigChange] = []
    private var observer: NSObjectProtocol?

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = try makeTempDir()
        originalConfig = GeneralConfig.current
        originalTheme = Theme.current
        ConfigLoader.defaultRootOverrideForTesting = root
        GeneralConfig.setCurrentForTesting(.builtIn)
        Theme.setCurrentForTesting(Theme.builtIn)
        posted = []
        observer = NotificationCenter.default.addObserver(forName: .configDidChange, object: nil, queue: nil) {
            [weak self] note in
            let change = note.userInfo?[ConfigChange.userInfoKey] as? ConfigChange ?? []
            MainActor.assumeIsolated { self?.posted.append(change) }
        }
    }

    override func tearDownWithError() throws {
        observer.map(NotificationCenter.default.removeObserver)
        ConfigLoader.defaultRootOverrideForTesting = nil
        GeneralConfig.setCurrentForTesting(originalConfig)
        Theme.setCurrentForTesting(originalTheme)
        try super.tearDownWithError()
    }

    func test_apply_setsTheThemeWithoutBroadcastingOrWriting() throws {
        let gallery = GalleryTheme()

        gallery.apply(themeName: "dracula")

        XCTAssertEqual(Theme.current, expectedTheme(named: "dracula"))
        XCTAssertNotEqual(Theme.current, Theme.builtIn, "the gallery theme never landed")
        XCTAssertEqual(posted.count, 0, "a broadcast re-themes every window and publishes a mismatched theme.json")
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: root.path), [],
            "picking a theme in the gallery wrote to the config")
        XCTAssertNil(GeneralConfig.current.themeName, "the gallery changed the config's theme")
    }

    func test_restore_afterAnOverride_broadcastsTheConfigThemeBack() {
        let gallery = GalleryTheme()
        gallery.apply(themeName: "dracula")

        gallery.restore()

        XCTAssertEqual(Theme.current, Theme.builtIn, "closing the gallery left its theme in place")
        XCTAssertEqual(posted.count, 1)
        XCTAssertTrue(posted.first?.contains(.theme) ?? false, "the restore did not tell windows to re-theme")
    }

    func test_restore_withNoOverride_postsNothing() {
        GalleryTheme().restore()

        XCTAssertEqual(posted.count, 0, "closing an untouched gallery reloaded the config")
    }

    func test_restore_afterAConfigReload_postsNothing() {
        let gallery = GalleryTheme()
        gallery.apply(themeName: "dracula")
        gallery.configDidReload()

        gallery.restore()

        XCTAssertEqual(posted.count, 0, "the config reload already restored the theme")
    }

    private func expectedTheme(named name: String) -> AppTheme {
        var general = GeneralConfig.builtIn
        general.themeName = name
        return ConfigLoader.loadAppTheme(general: general)
    }
}
