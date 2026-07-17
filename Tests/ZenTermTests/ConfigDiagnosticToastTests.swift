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

    /// `action` lost `chord` to `winner`.
    private func diagnostic(
        _ action: KeyInterceptor.ReservedChord, lost chord: Chord, to winner: KeyInterceptor.ReservedChord
    ) -> ConfigDiagnostic {
        ConfigDiagnostic(scope: .keybind(action), problem: .chordTaken(chord, by: winner))
    }

    private var splitVerticalLostBackslash: ConfigDiagnostic {
        diagnostic(.splitVertical, lost: Chord(command: true, shift: true, key: "\\"), to: .toggleZoom)
    }

    private var newTabLostCmdT: ConfigDiagnostic {
        diagnostic(.newTab, lost: Chord(command: true, key: "t"), to: .toggleToolFloat("btop"))
    }

    func test_noDiagnostics_producesNoToast() {
        XCTAssertNil(ConfigDiagnostic.toast(for: []), "a clean config must stay silent")
    }

    // MARK: the announce gate
    //
    // Every in-app write reloads too, so the toast is gated on the conflict set CHANGING. That gate
    // is the one thing that can silently suppress the whole feature, so it gets a truth table.

    func test_announce_newConflict_speaksUp() {
        let one = [splitVerticalLostBackslash]
        XCTAssertNotNil(ConfigDiagnostic.announcement(for: one, alreadyAnnounced: []))
    }

    func test_announce_sameConflictTwice_staysQuiet() {
        // A Settings rebind reloads the config; re-announcing an unchanged conflict on every edit
        // would nag, and the Keybinds row already says it inline.
        let one = [splitVerticalLostBackslash]
        XCTAssertNil(ConfigDiagnostic.announcement(for: one, alreadyAnnounced: one))
    }

    func test_announce_aChangedConflictSet_speaksUpAgain() {
        let before = [splitVerticalLostBackslash]
        let after = before + [newTabLostCmdT]
        XCTAssertNotNil(ConfigDiagnostic.announcement(for: after, alreadyAnnounced: before))
    }

    func test_announce_conflictResolved_staysQuiet() {
        // Fixing the config shouldn't toast "all clear" — the chip coming back says it.
        let before = [splitVerticalLostBackslash]
        XCTAssertNil(ConfigDiagnostic.announcement(for: [], alreadyAnnounced: before))
    }

    func test_announce_cleanConfigStaysQuietOnEveryReload() {
        XCTAssertNil(ConfigDiagnostic.announcement(for: [], alreadyAnnounced: []))
    }

    func test_oneProblem_keepsTheFullSentence() throws {
        // A single problem has no list to be terse for, and its title isn't doing the framing a
        // count does — so it says where this came from.
        let content = try XCTUnwrap(ConfigDiagnostic.toast(for: [splitVerticalLostBackslash]))
        XCTAssertEqual(content.variant, .warning, "a working-but-surprising config is a warning, not a failure")
        XCTAssertEqual(content.title, "Split Vertically has no shortcut")
        XCTAssertEqual(content.message, "⌘⇧\\ went to toggle_zoom in your config.")
    }

    func test_severalProblems_areOneCompactLineEach() throws {
        let content = try XCTUnwrap(ConfigDiagnostic.toast(for: [splitVerticalLostBackslash, newTabLostCmdT]))
        XCTAssertEqual(content.title, "2 problems in your config")
        XCTAssertEqual(
            content.message,
            """
            Split Vertically
              ⌘⇧\\ → toggle_zoom

            New Tab
              ⌘T → toggle_float:btop
            """)
        XCTAssertFalse(
            content.message.contains("in your config"),
            "the title already says it; repeating it per line is what forced the wrap")
    }

    /// Measures the copy against the card's real budget. The string assertion above can't see this:
    /// the first version of this listing read fine as text and wrapped mid-phrase at 236pt, because
    /// character count isn't width. Every word in a summary line pays rent here.
    func test_summaryLines_fitTheToastWithoutWrapping() throws {
        let realistic: [ConfigDiagnostic] = [
            splitVerticalLostBackslash,
            newTabLostCmdT,
            // The wide end of what's reachable: a long action title and a long winning token.
            diagnostic(.toggleBottomDrawer, lost: Chord(command: true, key: "b"), to: .toggleRightDrawer),
            ConfigDiagnostic(
                scope: .keybind(.toggleCommandPalette),
                problem: .unusableBind(Chord(command: true, key: "|"))),
        ]
        for diagnostic in realistic {
            for line in diagnostic.summary.split(separator: "\n") {
                let width = (String(line) as NSString)
                    .size(withAttributes: [.font: ToastView.messageFont]).width
                XCTAssertLessThanOrEqual(
                    width, ToastView.messageMaxWidth,
                    "wraps at \(Int(width))pt > \(Int(ToastView.messageMaxWidth))pt: \(line)")
            }
        }
    }

    func test_unusableBind_readsDifferentlyFromAStolenChord() {
        // Different claims: the action still HAS its default; the config line is what's dead.
        let unusable = ConfigDiagnostic(
            scope: .keybind(.splitVertical), problem: .unusableBind(Chord(command: true, key: "|")))
        XCTAssertEqual(unusable.headline, "Split Vertically has an unusable shortcut")
        XCTAssertEqual(unusable.detail, "cmd+| can't be typed")
        XCTAssertTrue(unusable.message.contains("split_vertical=cmd+|"), unusable.message)
    }

    func test_announce_sameConflictsInADifferentOrder_staysQuiet() {
        // Diagnostics come out in config-line order and ConfigWriter SORTS the lines it emits, so a
        // Settings write can reorder them without changing a thing. An order-sensitive gate would
        // re-toast conflicts the user already saw.
        let a = splitVerticalLostBackslash
        let b = newTabLostCmdT
        XCTAssertNil(ConfigDiagnostic.announcement(for: [a, b], alreadyAnnounced: [b, a]))
    }

    func test_aFloatLosingItsChord_isSurfacedByTheToast() throws {
        // Tool floats have no Keybinds row (they're file-only), so the inline note can never reach
        // them — the toast is the only thing that can tell a user their float toggle went dead.
        try "float = title:btop command:btop key:cmd+y title:BTop\nkeybind = new_tab=cmd+y\n"
            .write(to: tempRoot.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        AppConfig.reload()

        XCTAssertEqual(GeneralConfig.current.keymapDiagnostics.map(\.scope), [.keybind(.toggleToolFloat("btop"))])
        let content = try XCTUnwrap(ConfigDiagnostic.toast(for: GeneralConfig.current.keymapDiagnostics))
        // "BTop", the float's title — not "btop", its id. The headline has to be derived on READ:
        // diagnostics are built inside the parse, while GeneralConfig.current still holds the old
        // config, so resolving the name back then reads the previous launch's floats and finds none.
        XCTAssertTrue(content.title.contains("BTop"), content.title)
        XCTAssertFalse(content.title.contains("btop has"), "fell back to the raw id: \(content.title)")
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
