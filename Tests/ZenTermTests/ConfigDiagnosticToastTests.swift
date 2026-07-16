import AppKit
import XCTest

@testable import ZenTerm

/// The reload notice for keybind conflicts (ZEN-142). The inline note on a Keybinds row only
/// reaches someone already looking at that row — a user who broke their config by hand has no
/// reason to go there, so the reload has to announce itself.
final class ConfigDiagnosticToastTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenterm-diagnostic-toast-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        ConfigLoader.defaultRootOverrideForTesting = tempRoot
        AppConfig.reload()  // pin to defaults, never the real user config
    }

    override func tearDownWithError() throws {
        ConfigLoader.defaultRootOverrideForTesting = nil
        AppConfig.reload()
        try? FileManager.default.removeItem(at: tempRoot)
        try super.tearDownWithError()
    }

    private func diagnostic(_ action: KeyInterceptor.ReservedChord, _ message: String) -> ConfigDiagnostic {
        ConfigDiagnostic(scope: .keybind(action), message: message)
    }

    func test_noDiagnostics_producesNoToast() {
        XCTAssertNil(ConfigDiagnostic.toast(for: []), "a clean config must stay silent")
    }

    func test_oneDiagnostic_namesTheActionAndTheConfigToken() throws {
        let content = try XCTUnwrap(
            ConfigDiagnostic.toast(for: [diagnostic(.splitVertical, "⌘⇧\\ went to toggle_zoom in your config.")]))
        XCTAssertEqual(content.variant, .warning, "a working-but-surprising config is a warning, not a failure")
        XCTAssertTrue(content.title.contains("Split Vertically"), content.title)
        // The body has to carry the config-file token — that's what the user greps for to fix it.
        XCTAssertTrue(content.message.contains("toggle_zoom"), content.message)
        XCTAssertTrue(content.message.contains("⌘⇧\\"), content.message)
    }

    func test_severalDiagnostics_countThemAndNameThem() throws {
        let content = try XCTUnwrap(
            ConfigDiagnostic.toast(for: [
                diagnostic(.splitVertical, "⌘⇧\\ went to toggle_zoom in your config."),
                diagnostic(.newTab, "⌘T went to toggle_float:btop in your config."),
            ]))
        XCTAssertTrue(content.title.contains("2"), content.title)
        XCTAssertTrue(content.message.contains("Split Vertically"), content.message)
        XCTAssertTrue(content.message.contains("New Tab"), content.message)
    }

    func test_aFloatLosingItsChord_isSurfacedByTheToast() throws {
        // Tool floats have no Keybinds row (they're file-only), so the inline note can never reach
        // them — the toast is the only thing that can tell a user their float toggle went dead.
        try "float = id:btop command:btop key:cmd+y title:BTop\nkeybind = new_tab=cmd+y\n"
            .write(to: tempRoot.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        AppConfig.reload()

        XCTAssertEqual(GeneralConfig.current.keymapDiagnostics.map(\.scope), [.keybind(.toggleToolFloat("btop"))])
        let content = try XCTUnwrap(ConfigDiagnostic.toast(for: GeneralConfig.current.keymapDiagnostics))
        XCTAssertTrue(content.title.contains("BTop"), content.title)
        XCTAssertTrue(content.message.contains("new_tab"), content.message)
    }

    /// The real config path: a hand-edited file that steals a chord must produce a toast-worthy
    /// diagnostic, not just an inline row note.
    func test_aConfigThatStealsAChord_producesAToast() throws {
        try "keybind = toggle_zoom=cmd+shift+\\\n"
            .write(to: tempRoot.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        AppConfig.reload()

        let content = try XCTUnwrap(ConfigDiagnostic.toast(for: GeneralConfig.current.keymapDiagnostics))
        XCTAssertTrue(content.title.contains("Split Vertically"), content.title)
        XCTAssertTrue(content.message.contains("toggle_zoom"), content.message)
    }
}
