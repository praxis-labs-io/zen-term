import TerminalKit
import XCTest

@testable import ZenTerm

/// Guards the shipped reference files in `docs/config/` against drifting from the real
/// defaults: the annotated `config` is all-commented, so it must parse to `.builtIn`, and
/// `themes/rose-pine-moon` carries the Rosé Pine Moon values, so it must parse to
/// `Theme.rosePineMoon`.
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
        general.themeName = "rose-pine-moon"  // resolves docs/config/themes/rose-pine-moon
        let terminal = ConfigLoader.loadAppTheme(configRoot: docsConfig, general: general).terminal
        let expected = Theme.rosePineMoon
        XCTAssertEqual(terminal.background, expected.background)
        XCTAssertEqual(terminal.foreground, expected.foreground)
        XCTAssertEqual(terminal.cursor, expected.cursor)
        XCTAssertEqual(terminal.selectionBackground, expected.selectionBackground)
        XCTAssertEqual(terminal.ansi, expected.ansi)
    }
}
