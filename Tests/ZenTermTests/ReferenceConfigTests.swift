import TerminalKit
import XCTest

@testable import ZenTerm

final class ReferenceConfigTests: XCTestCase {
    private var docsConfig: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("docs/config", isDirectory: true)
    }

    func test_referenceConfig_isAllCommented_yieldingBuiltIn() {
        XCTAssertEqual(ConfigLoader.loadGeneralConfig(configRoot: docsConfig), .builtIn)
    }

    func test_referenceWorkspaces_isAllCommented_yieldingEmpty() {
        XCTAssertEqual(ConfigLoader.loadWorkspaces(configRoot: docsConfig), [])
    }

    func test_referenceTheme_matchesBuiltInDefault() {
        var general = GeneralConfig.builtIn
        general.themeName = ThemeCatalog.defaultThemeName
        let terminal = ConfigLoader.loadAppTheme(configRoot: docsConfig, general: general).terminal
        let expected = Theme.rosePineZen
        XCTAssertEqual(terminal.background, expected.background)
        XCTAssertEqual(terminal.foreground, expected.foreground)
        XCTAssertEqual(terminal.cursor, expected.cursor)
        XCTAssertEqual(terminal.selectionBackground, expected.selectionBackground)
        XCTAssertEqual(terminal.ansi, expected.ansi)
    }

    func test_referenceTheme_namesTheSameColorschemeAsTheBundledDefault() throws {
        let bundled = try XCTUnwrap(ThemeCatalog.bundledURL(for: ThemeCatalog.defaultThemeName))
        let reference =
            docsConfig
            .appendingPathComponent("themes")
            .appendingPathComponent(ThemeCatalog.defaultThemeName)

        XCTAssertEqual(
            ThemePublisher.nvimColorscheme(inThemeAt: reference),
            ThemePublisher.nvimColorscheme(inThemeAt: bundled))
    }
}
