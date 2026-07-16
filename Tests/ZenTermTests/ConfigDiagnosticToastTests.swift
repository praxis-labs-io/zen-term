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

    // MARK: the announce gate
    //
    // Every in-app write reloads too, so the toast is gated on the conflict set CHANGING. That gate
    // is the one thing that can silently suppress the whole feature, so it gets a truth table.

    func test_announce_newConflict_speaksUp() {
        let one = [diagnostic(.splitVertical, "⌘⇧\\ went to toggle_zoom in your config.")]
        XCTAssertNotNil(ConfigDiagnostic.announcement(for: one, alreadyAnnounced: []))
    }

    func test_announce_sameConflictTwice_staysQuiet() {
        // A Settings rebind reloads the config; re-announcing an unchanged conflict on every edit
        // would nag, and the Keybinds row already says it inline.
        let one = [diagnostic(.splitVertical, "⌘⇧\\ went to toggle_zoom in your config.")]
        XCTAssertNil(ConfigDiagnostic.announcement(for: one, alreadyAnnounced: one))
    }

    func test_announce_aChangedConflictSet_speaksUpAgain() {
        let before = [diagnostic(.splitVertical, "⌘⇧\\ went to toggle_zoom in your config.")]
        let after = before + [diagnostic(.newTab, "⌘T went to toggle_float:btop in your config.")]
        XCTAssertNotNil(ConfigDiagnostic.announcement(for: after, alreadyAnnounced: before))
    }

    func test_announce_conflictResolved_staysQuiet() {
        // Fixing the config shouldn't toast "all clear" — the chip coming back says it.
        let before = [diagnostic(.splitVertical, "⌘⇧\\ went to toggle_zoom in your config.")]
        XCTAssertNil(ConfigDiagnostic.announcement(for: [], alreadyAnnounced: before))
    }

    func test_announce_cleanConfigStaysQuietOnEveryReload() {
        XCTAssertNil(ConfigDiagnostic.announcement(for: [], alreadyAnnounced: []))
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

    func test_severalDiagnostics_countThemAndCarryEveryChordAndToken() throws {
        let content = try XCTUnwrap(
            ConfigDiagnostic.toast(for: [
                diagnostic(.splitVertical, "⌘⇧\\ went to toggle_zoom in your config."),
                diagnostic(.newTab, "⌘T went to toggle_float:btop in your config."),
            ]))
        XCTAssertTrue(content.title.contains("2"), content.title)
        // Not just the action names: each line has to carry the chord and the token that took it,
        // or the toast says something is wrong without saying what to go fix.
        for expected in ["Split Vertically", "⌘⇧\\", "toggle_zoom", "New Tab", "⌘T", "toggle_float:btop"] {
            XCTAssertTrue(content.message.contains(expected), "missing \(expected) in:\n\(content.message)")
        }
    }

    func test_announce_sameConflictsInADifferentOrder_staysQuiet() {
        // Diagnostics come out in config-line order and ConfigWriter SORTS the lines it emits, so a
        // Settings write can reorder them without changing a thing. An order-sensitive gate would
        // re-toast conflicts the user already saw.
        let a = diagnostic(.splitVertical, "⌘⇧\\ went to toggle_zoom in your config.")
        let b = diagnostic(.newTab, "⌘T went to toggle_float:btop in your config.")
        XCTAssertNil(ConfigDiagnostic.announcement(for: [a, b], alreadyAnnounced: [b, a]))
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
