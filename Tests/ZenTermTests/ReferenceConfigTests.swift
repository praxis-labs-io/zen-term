import TerminalKit
import XCTest

@testable import ZenTerm

/// Guards the shipped reference files in `docs/config/` against drifting from the real
/// defaults: the annotated `config` is all-commented, so it must parse to `.builtIn`, and
/// `themes/rose-pine-zen` carries the shipped default's values, so it must parse to
/// `Theme.rosePineZen`.
final class ReferenceConfigTests: XCTestCase {
    /// `<package root>/docs/config`, located relative to this source file.
    private var docsConfig: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // ZenTermTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // package root
            .appendingPathComponent("docs/config", isDirectory: true)
    }

    func test_referenceConfig_isAllCommented_yieldingBuiltIn() {
        XCTAssertEqual(ConfigLoader.loadGeneralConfig(configRoot: docsConfig), .builtIn)
    }

    func test_referenceWorkspaces_isAllCommented_yieldingEmpty() {
        // The shipped reference is inert — copying it is a clean slate (empty picker) until
        // the user uncomments a section. Proves no example line is accidentally live.
        XCTAssertEqual(ConfigLoader.loadWorkspaces(configRoot: docsConfig), [])
    }

    func test_referenceTheme_matchesBuiltInDefault() {
        var general = GeneralConfig.builtIn
        // The user path wins, so this resolves docs/config/themes/, not the bundled file.
        general.themeName = ThemeCatalog.defaultThemeName
        let terminal = ConfigLoader.loadAppTheme(configRoot: docsConfig, general: general).terminal
        let expected = Theme.rosePineZen
        XCTAssertEqual(terminal.background, expected.background)
        XCTAssertEqual(terminal.foreground, expected.foreground)
        XCTAssertEqual(terminal.cursor, expected.cursor)
        XCTAssertEqual(terminal.selectionBackground, expected.selectionBackground)
        XCTAssertEqual(terminal.ansi, expected.ansi)
    }

    /// The reference file is what a user copies to start their own theme, so its
    /// `nvim-colorscheme` has to name what the bundled default names. Drift here hands the editor
    /// a different colorscheme than the theme the user picked, and the parser drops the key, so
    /// `test_referenceTheme_matchesBuiltInDefault` above stays green through it.
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
