import AppKit
import XCTest

@testable import ZenTerm

final class ConfigDiagnosticToastTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenterm-diagnostic-toast-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        ConfigLoader.defaultRootOverrideForTesting = tempRoot
        AppConfig.reload()
    }

    override func tearDownWithError() throws {
        ConfigLoader.defaultRootOverrideForTesting = nil
        AppConfig.reload()
        try? FileManager.default.removeItem(at: tempRoot)
        try super.tearDownWithError()
    }

    private func diagnostic(
        _ action: KeyInterceptor.ReservedChord, lost chord: Chord, to winner: KeyInterceptor.ReservedChord
    ) -> ConfigDiagnostic {
        ConfigDiagnostic(scope: .keybind(action), problem: .chordTaken(chord, by: winner))
    }

    private var splitVerticalLostBackslash: ConfigDiagnostic {
        diagnostic(.splitVertical, lost: Chord(command: true, shift: true, key: "\\"), to: .toggleZoom)
    }

    private var paletteOnAMenuChord: ConfigDiagnostic {
        ConfigDiagnostic(
            scope: .keybind(.toggleCommandPalette),
            problem: .menuBind(Chord(command: true, key: "q"), menuItem: "Quit"))
    }

    private var newTabUnusableBind: ConfigDiagnostic {
        ConfigDiagnostic(scope: .keybind(.newTab), problem: .unusableBind(Chord(command: true, key: "|")))
    }

    private var newTabLostCmdT: ConfigDiagnostic {
        diagnostic(.newTab, lost: Chord(command: true, key: "t"), to: .toggleToolFloat("btop"))
    }

    func test_noDiagnostics_producesNoToast() {
        XCTAssertNil(ConfigDiagnostic.toast(for: []), "a clean config must stay silent")
    }

    func test_announce_newConflict_speaksUp() {
        let one = [paletteOnAMenuChord]
        XCTAssertNotNil(ConfigDiagnostic.announcement(for: one, alreadyAnnounced: []))
    }

    func test_announce_sameConflictTwice_staysQuiet() {
        let one = [paletteOnAMenuChord]
        XCTAssertNil(ConfigDiagnostic.announcement(for: one, alreadyAnnounced: one))
    }

    func test_announce_aChangedConflictSet_speaksUpAgain() {
        let before = [paletteOnAMenuChord]
        let after = before + [newTabUnusableBind]
        XCTAssertNotNil(ConfigDiagnostic.announcement(for: after, alreadyAnnounced: before))
    }

    func test_announce_conflictResolved_staysQuiet() {
        let before = [paletteOnAMenuChord]
        XCTAssertNil(ConfigDiagnostic.announcement(for: [], alreadyAnnounced: before))
    }

    func test_announce_cleanConfigStaysQuietOnEveryReload() {
        XCTAssertNil(ConfigDiagnostic.announcement(for: [], alreadyAnnounced: []))
    }

    func test_oneProblem_keepsTheFullSentence() throws {
        let content = try XCTUnwrap(ConfigDiagnostic.toast(for: [newTabUnusableBind]))
        XCTAssertEqual(content.variant, .warning, "a working-but-surprising config is a warning, not a failure")
        XCTAssertEqual(content.title, "New Tab has an unusable shortcut")
        XCTAssertEqual(content.message, "new_tab=cmd+| can't be typed on your keyboard. Ignoring it.")
    }

    func test_chordTaken_readsAsAStandingState() {
        XCTAssertEqual(splitVerticalLostBackslash.message, "⌘⇧\\ goes to toggle_focus_mode.")
        XCTAssertTrue(splitVerticalLostBackslash.isChordConflict, "it gets its own card")
        XCTAssertFalse(newTabUnusableBind.isChordConflict)
        XCTAssertFalse(paletteOnAMenuChord.isChordConflict)
    }

    func test_severalProblems_areOneCompactLineEach() throws {
        let content = try XCTUnwrap(ConfigDiagnostic.toast(for: [paletteOnAMenuChord, newTabUnusableBind]))
        XCTAssertEqual(content.title, "2 problems in your config")
        XCTAssertEqual(
            content.message,
            """
            Command Palette
              cmd+q → Quit

            New Tab
              cmd+| can't be typed
            """)
        XCTAssertFalse(
            content.message.contains("in your config"),
            "the title already says it; repeating it per line is what forced the wrap")
    }

    func test_summaryLines_fitTheToastWithoutWrapping() throws {
        let realistic: [ConfigDiagnostic] = [
            splitVerticalLostBackslash,
            newTabLostCmdT,
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
        let unusable = ConfigDiagnostic(
            scope: .keybind(.splitVertical), problem: .unusableBind(Chord(command: true, key: "|")))
        XCTAssertEqual(unusable.headline, "Split Vertically has an unusable shortcut")
        XCTAssertEqual(unusable.detail, "cmd+| can't be typed")
        XCTAssertTrue(unusable.message.contains("split_vertical=cmd+|"), unusable.message)
    }

    func test_invalidValue_phrasings() {
        let diagnostic = ConfigDiagnostic(
            scope: .setting(key: "cursor-style"),
            problem: .invalidValue(got: "beam", expected: "block, bar, or underline"))
        XCTAssertEqual(diagnostic.headline, "cursor-style has an invalid value")
        XCTAssertEqual(
            diagnostic.message, "cursor-style = beam isn't valid (block, bar, or underline). Using the default.")
        XCTAssertEqual(diagnostic.detail, "beam isn't valid")
    }

    func test_clamped_phrasings() {
        let diagnostic = ConfigDiagnostic(
            scope: .setting(key: "font-size"), problem: .clamped(value: "200", to: "72"))
        XCTAssertEqual(diagnostic.headline, "font-size is out of range")
        XCTAssertEqual(diagnostic.message, "font-size = 200 is out of range. Using 72.")
        XCTAssertEqual(diagnostic.detail, "200 → 72")
    }

    func test_droppedFloat_phrasings() {
        let diagnostic = ConfigDiagnostic(
            scope: .toolFloat(label: "Open Lazygit"), problem: .floatMissingField("command:"))
        XCTAssertEqual(diagnostic.headline, "A tool float was ignored")
        XCTAssertEqual(diagnostic.message, "Open Lazygit is missing command:. Ignoring this tool float.")
    }

    func test_floatFieldInvalid_phrasings() {
        let diagnostic = ConfigDiagnostic(
            scope: .toolFloatField(id: "open-lazygit", label: "Open Lazygit"),
            problem: .floatFieldInvalid(field: "width:", got: "big", using: "0.85"))
        XCTAssertEqual(diagnostic.headline, "Open Lazygit has an invalid setting")
        XCTAssertEqual(diagnostic.message, "Open Lazygit: width:big isn't valid. Using 0.85.")
        XCTAssertEqual(diagnostic.detail, "width:big isn't valid")
    }

    func test_floatFieldClamped_phrasings() {
        let diagnostic = ConfigDiagnostic(
            scope: .toolFloatField(id: "open-lazygit", label: "Open Lazygit"),
            problem: .floatFieldClamped(field: "height:", got: "5", to: "1"))
        XCTAssertEqual(diagnostic.headline, "Open Lazygit has an invalid setting")
        XCTAssertEqual(diagnostic.message, "Open Lazygit: height:5 is out of range. Using 1.")
        XCTAssertEqual(diagnostic.detail, "height:5 → 1")
    }

    func test_nonKeybindProblems_surfaceInTheToast() throws {
        let content = try XCTUnwrap(
            ConfigDiagnostic.toast(for: [
                ConfigDiagnostic(scope: .setting(key: "font-size"), problem: .clamped(value: "200", to: "72")),
                ConfigDiagnostic(scope: .toolFloat(label: "Open Lazygit"), problem: .floatMissingField("command:")),
            ]))
        XCTAssertEqual(content.title, "2 problems in your config")
        XCTAssertTrue(content.message.contains("font-size"), content.message)
        XCTAssertTrue(content.message.contains("Open Lazygit"), content.message)
    }

    func test_nonKeybindSummaryLines_fitTheToastWithoutWrapping() {
        let realistic: [ConfigDiagnostic] = [
            ConfigDiagnostic(
                scope: .setting(key: "bottom-drawer-fraction"), problem: .clamped(value: "0.05", to: "0.1")),
            ConfigDiagnostic(
                scope: .setting(key: "cursor-style"),
                problem: .invalidValue(got: "rectangle", expected: "block, bar, or underline")),
            ConfigDiagnostic(
                scope: .toolFloat(label: "Open Lazygit in Worktree"), problem: .floatMissingField("command:")),
            ConfigDiagnostic(
                scope: .toolFloatField(id: "open-lazygit-in-worktree", label: "Open Lazygit in Worktree"),
                problem: .floatFieldClamped(field: "height:", got: "0.05", to: "0.2")),
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

    func test_announce_sameConflictsInADifferentOrder_staysQuiet() {
        let a = splitVerticalLostBackslash
        let b = newTabLostCmdT
        XCTAssertNil(ConfigDiagnostic.announcement(for: [a, b], alreadyAnnounced: [b, a]))
    }

    func test_aFloatLosingItsChord_isSurfacedByTheToast() throws {
        try "float = title:btop command:btop key:cmd+y title:BTop\nkeybind = new_tab=cmd+y\n"
            .write(to: tempRoot.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        AppConfig.reload()

        XCTAssertEqual(GeneralConfig.current.configDiagnostics.map(\.scope), [.keybind(.toggleToolFloat("btop"))])
        let content = try XCTUnwrap(ConfigDiagnostic.toast(for: GeneralConfig.current.configDiagnostics))
        XCTAssertTrue(content.title.contains("BTop"), content.title)
        XCTAssertFalse(content.title.contains("btop has"), "fell back to the raw id: \(content.title)")
        XCTAssertTrue(content.message.contains("new_tab"), content.message)
    }

    func test_aConfigThatStealsAChord_producesAToast() throws {
        try "keybind = toggle_focus_mode=cmd+d\n"
            .write(to: tempRoot.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        AppConfig.reload()

        let content = try XCTUnwrap(ConfigDiagnostic.toast(for: GeneralConfig.current.configDiagnostics))
        XCTAssertTrue(content.title.contains("Split Vertically"), content.title)
        XCTAssertTrue(content.message.contains("toggle_focus_mode"), content.message)
    }
}
