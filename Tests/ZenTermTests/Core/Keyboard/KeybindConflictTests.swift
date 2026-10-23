import XCTest

@testable import ZenTerm

final class KeybindConflictTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenterm-conflict-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        ConfigLoader.defaultRootOverrideForTesting = tempRoot
    }

    override func tearDownWithError() throws {
        ConfigLoader.defaultRootOverrideForTesting = nil
        try? FileManager.default.removeItem(at: tempRoot)
        try super.tearDownWithError()
    }

    private func load(_ text: String) throws -> GeneralConfig {
        try text.write(to: tempRoot.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        return ConfigLoader.loadGeneralConfig(configRoot: tempRoot)
    }

    private func write(_ overrides: KeymapOverrides) throws -> String {
        try ConfigWriter.apply(keybinds: overrides, configRoot: tempRoot)
        return try String(contentsOf: tempRoot.appendingPathComponent("config"), encoding: .utf8)
    }

    func test_aKeybindLineTakingAChord_isOneRevertableConflict() throws {
        let config = try load("keybind = split_vertical=cmd+shift+p\n")

        let conflicts = KeybindConflict.all(in: config)

        XCTAssertEqual(conflicts.count, 1, "\(conflicts)")
        XCTAssertEqual(conflicts[0].loser, .toggleCommandPalette)
        XCTAssertEqual(conflicts[0].winner, .splitVertical)
        XCTAssertEqual(conflicts[0].chord, Chord(command: true, shift: true, key: "p"))
        XCTAssertTrue(conflicts[0].isRevertable)
    }

    func test_aFloatTakingAChord_isNotRevertable() throws {
        let config = try load("float = title:lazygit command:lazygit key:cmd+j\n")

        let conflicts = KeybindConflict.all(in: config)

        XCTAssertEqual(conflicts.count, 1, "\(conflicts)")
        XCTAssertEqual(conflicts[0].loser, .scrollToSelection)
        XCTAssertFalse(conflicts[0].isRevertable)
    }

    func test_threeConflicts_readAsThree() throws {
        let config = try load(
            """
            float = order:1 title:lazygit command:lazygit key:cmd+j
            float = order:2 title:gitdash command:gd key:cmd+k
            float = order:3 title:nvim command:nvim key:cmd+e
            """)

        XCTAssertEqual(
            Set(KeybindConflict.all(in: config).map(\.loser)),
            [.scrollToSelection, .clearScreen, .searchSelection])
    }

    func test_aPlainRebind_isNoConflict() throws {
        let config = try load("keybind = new_tab=cmd+shift+opt+ctrl+y\n")

        XCTAssertEqual(KeybindConflict.all(in: config), [])
    }

    func test_accept_writesTheUnsetAndLeavesTheLineThatTookIt() throws {
        let config = try load("keybind = split_vertical=cmd+shift+p\n")
        let conflict = KeybindConflict.all(in: config)[0]

        let text = try write(conflict.accepting(KeymapOverrides(config: config)))

        XCTAssertTrue(text.contains("keybind = toggle_command_palette=none"), text)
        XCTAssertTrue(text.contains("keybind = split_vertical=cmd+shift+p"), text)
        let reloaded = ConfigLoader.loadGeneralConfig(configRoot: tempRoot)
        XCTAssertEqual(KeybindConflict.all(in: reloaded), [], "and it stops being reported")
    }

    func test_revert_dropsTheLineAndPutsBothBack() throws {
        let config = try load("keybind = split_vertical=cmd+shift+p\n")
        let conflict = KeybindConflict.all(in: config)[0]

        let text = try write(conflict.reverting(KeymapOverrides(config: config)))

        XCTAssertFalse(text.contains("split_vertical"), text)
        XCTAssertFalse(text.contains("toggle_command_palette"), text)
        let reloaded = ConfigLoader.loadGeneralConfig(configRoot: tempRoot)
        XCTAssertEqual(reloaded.keymap[Chord(command: true, shift: true, key: "p")], .toggleCommandPalette)
        XCTAssertEqual(reloaded.keymap[Chord(command: true, key: "d")], .splitVertical)
        XCTAssertEqual(KeybindConflict.all(in: reloaded), [])
    }

    func test_acceptingOne_leavesTheOthersReported() throws {
        let config = try load(
            """
            float = order:1 title:lazygit command:lazygit key:cmd+j
            float = order:2 title:nvim command:nvim key:cmd+e
            """)
        let viewer = try XCTUnwrap(
            KeybindConflict.all(in: config).first { $0.loser == .scrollToSelection })

        _ = try write(viewer.accepting(KeymapOverrides(config: config)))

        let reloaded = ConfigLoader.loadGeneralConfig(configRoot: tempRoot)
        XCTAssertEqual(KeybindConflict.all(in: reloaded).map(\.loser), [.searchSelection])
    }

    func test_aFloatAsTheLoser_cannotBeAccepted() throws {
        let config = try load("float = title:lazygit command:lazygit key:cmd+y\nkeybind = new_tab=cmd+y\n")

        let conflict = try XCTUnwrap(KeybindConflict.all(in: config).first)

        XCTAssertEqual(conflict.winner, .newTab)
        XCTAssertFalse(conflict.isAcceptable, "there is no line Accept could write that survives")
        XCTAssertTrue(conflict.isRevertable, "but the keybind line that took it can go")
    }

    func test_aConflictWithNoAnswer_isNotReported() throws {
        let config = try load(
            "float = order:1 title:a command:a key:cmd+y\nfloat = order:2 title:b command:b key:cmd+y\n")

        XCTAssertEqual(KeybindConflict.all(in: config), [])
    }

    func test_revert_leavesAnUnrelatedBindingAlone() throws {
        let config = try load("keybind = toggle_zoom=cmd+shift+p\nkeybind = new_tab=cmd+f\n")
        let conflict = try XCTUnwrap(KeybindConflict.all(in: config).first)
        XCTAssertEqual(conflict.loser, .toggleCommandPalette)

        let text = try write(conflict.reverting(KeymapOverrides(config: config)))

        XCTAssertTrue(text.contains("keybind = new_tab=cmd+f"), text)
        XCTAssertFalse(text.contains("toggle_zoom"), text)
        let reloaded = ConfigLoader.loadGeneralConfig(configRoot: tempRoot)
        XCTAssertEqual(reloaded.keymap[Chord(command: true, shift: true, key: "p")], .toggleCommandPalette)
        XCTAssertEqual(reloaded.keymap[Chord(command: true, key: "f")], .newTab, "still the user's")
    }

    func test_theCardAndTheRow_useTheSameSentence() throws {
        let config = try load("keybind = split_vertical=cmd+shift+p\n")
        let conflict = try XCTUnwrap(KeybindConflict.all(in: config).first)

        let rowMessage = config.configDiagnostics.first { $0.scope == .keybind(.toggleCommandPalette) }?
            .message
        XCTAssertEqual(conflict.message, rowMessage)
    }

    func test_revert_leavesFloatLinesAlone() throws {
        let config = try load(
            "float = title:lazygit command:lazygit key:cmd+shift+j\nkeybind = split_vertical=cmd+shift+p\n")
        let conflict = try XCTUnwrap(KeybindConflict.all(in: config).first { $0.isRevertable })

        let text = try write(conflict.reverting(KeymapOverrides(config: config)))

        XCTAssertTrue(text.contains("float = title:lazygit command:lazygit key:cmd+shift+j"), text)
    }
}
