import TerminalKit
import XCTest

@testable import ZenTerm

/// The `accent-color` key's parse and load path: a token resolves to a slot, a bad one
/// falls back with a diagnostic the Settings row can render, and the whole thing reaches
/// `Theme.current.chrome.accent` through a real config file rather than a hand-built struct.
final class AccentColorConfigTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenterm-accent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        ConfigLoader.defaultRootOverrideForTesting = tempRoot
    }

    override func tearDownWithError() throws {
        ConfigLoader.defaultRootOverrideForTesting = nil
        AppConfig.reload()
        try? FileManager.default.removeItem(at: tempRoot)
        try super.tearDownWithError()
    }

    private func writeConfig(_ text: String) throws {
        try text.write(
            to: tempRoot.appendingPathComponent("config"), atomically: true, encoding: .utf8)
    }

    func test_hueName_parsesToItsSlot() throws {
        try writeConfig("accent-color = bright-cyan\n")
        let config = ConfigLoader.loadGeneralConfig()
        XCTAssertEqual(config.accentColor, .brightCyan)
        XCTAssertTrue(config.configDiagnostics.isEmpty)
    }

    func test_tokenIsCaseInsensitive() throws {
        try writeConfig("accent-color = Magenta\n")
        XCTAssertEqual(ConfigLoader.loadGeneralConfig().accentColor, .magenta)
    }

    func test_absentKey_leavesTheSlotUnset() throws {
        try writeConfig("font-size = 13\n")
        XCTAssertNil(ConfigLoader.loadGeneralConfig().accentColor)
    }

    /// A bad value must fall back *and* leave a trail on the row that owns the key — the app's
    /// contract is that nothing in the config can crash it and every fallback is visible.
    func test_unknownToken_fallsBackAndReportsOnTheRow() throws {
        try writeConfig("accent-color = chartreuse\n")
        let config = ConfigLoader.loadGeneralConfig()

        XCTAssertNil(config.accentColor)
        XCTAssertTrue(
            config.configDiagnostics.contains { $0.scope == .setting(key: "accent-color") },
            "expected a diagnostic scoped to the accent-color row, got: \(config.configDiagnostics)")
    }

    /// The end of the chain: a config file has to actually move the color the chrome paints with.
    func test_theKeyReachesTheResolvedChromeAccent() throws {
        try writeConfig("accent-color = green\n")
        AppConfig.reload()

        XCTAssertEqual(Theme.current.chrome.accent, Theme.current.terminal.ansi[2])
        XCTAssertNotEqual(Theme.current.chrome.accent, Theme.current.terminal.ansi[5])
        // The roles that carry meaning stay where they were.
        XCTAssertEqual(Theme.current.chrome.info, Theme.current.terminal.ansi[4])
        XCTAssertEqual(Theme.current.chrome.destructive, Theme.current.terminal.ansi[1])
    }

    /// The slot is stored, not the color, so a theme swap re-resolves the same name against the new
    /// palette. Without this the accent would strand a color from the theme the user left behind.
    func test_theSlotReResolvesAgainstANewTheme() throws {
        let themes = tempRoot.appendingPathComponent("themes", isDirectory: true)
        try FileManager.default.createDirectory(at: themes, withIntermediateDirectories: true)
        try "palette = 2=#00ff00\n".write(
            to: themes.appendingPathComponent("greenish"), atomically: true, encoding: .utf8)

        try writeConfig("accent-color = green\ntheme = greenish\n")
        AppConfig.reload()

        XCTAssertEqual(Theme.current.chrome.accent, TerminalColor(hex: "#00ff00"))
    }
}
