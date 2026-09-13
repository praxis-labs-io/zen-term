import TerminalKit
import XCTest

@testable import ZenTerm

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

    func test_unknownToken_fallsBackAndReportsOnTheRow() throws {
        try writeConfig("accent-color = chartreuse\n")
        let config = ConfigLoader.loadGeneralConfig()

        XCTAssertNil(config.accentColor)
        XCTAssertTrue(
            config.configDiagnostics.contains { $0.scope == .setting(key: "accent-color") },
            "expected a diagnostic scoped to the accent-color row, got: \(config.configDiagnostics)")
    }

    func test_theKeyReachesTheResolvedChromeAccent() throws {
        try writeConfig("accent-color = green\n")
        AppConfig.reload()

        XCTAssertEqual(Theme.current.chrome.accent, Theme.current.terminal.ansi[2])
        XCTAssertNotEqual(
            Theme.current.chrome.accent,
            Theme.current.terminal.ansi[AccentSlot.themeDefault.ansiIndex],
            "the key has not moved the accent off its default slot")
        XCTAssertEqual(Theme.current.chrome.info, Theme.current.terminal.ansi[4])
        XCTAssertEqual(Theme.current.chrome.destructive, Theme.current.terminal.ansi[1])
    }

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
