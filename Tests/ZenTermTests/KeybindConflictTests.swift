import XCTest

@testable import ZenTerm

/// The two answers to a chord conflict, and what each writes (ZEN-368).
///
/// Both are edits to the config, because the config is what created the conflict. Accept records
/// the loss. Revert puts both actions back on their defaults, which makes the offending line equal
/// to the defaults so `ConfigWriter`'s per-action diff stops emitting it. Neither needs a new
/// writer capability, and this is where that claim is checked rather than assumed.
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

    // MARK: reading them off the config

    func test_aKeybindLineTakingAChord_isOneRevertableConflict() throws {
        let config = try load("keybind = split_vertical=cmd+shift+p\n")

        let conflicts = KeybindConflict.all(in: config)

        XCTAssertEqual(conflicts.count, 1, "\(conflicts)")
        XCTAssertEqual(conflicts[0].loser, .toggleCommandPalette)
        XCTAssertEqual(conflicts[0].winner, .splitVertical)
        XCTAssertEqual(conflicts[0].chord, Chord(command: true, shift: true, key: "p"))
        XCTAssertTrue(conflicts[0].isRevertable)
    }

    /// A float's chord is the `key:` on its own line and `key:` is required, so there is nothing to
    /// back out to. The surfaces read this to decide whether to offer Revert at all.
    func test_aFloatTakingAChord_isNotRevertable() throws {
        let config = try load("float = title:lazygit command:lazygit key:cmd+g\n")

        let conflicts = KeybindConflict.all(in: config)

        XCTAssertEqual(conflicts.count, 1, "\(conflicts)")
        XCTAssertEqual(conflicts[0].loser, .openDiffViewer)
        XCTAssertFalse(conflicts[0].isRevertable)
    }

    /// One card each, so three lines are three decisions rather than one all-or-nothing prompt.
    func test_threeConflicts_readAsThree() throws {
        let config = try load(
            """
            float = order:1 title:lazygit command:lazygit key:cmd+g
            float = order:2 title:gitdash command:gd key:cmd+k
            float = order:3 title:nvim command:nvim key:cmd+e
            """)

        XCTAssertEqual(
            Set(KeybindConflict.all(in: config).map(\.loser)),
            [.openDiffViewer, .clearScreen, .searchSelection])
    }

    /// An action that merely moved is not a conflict. Only losing the last chord is.
    func test_aPlainRebind_isNoConflict() throws {
        let config = try load("keybind = new_tab=cmd+shift+opt+ctrl+y\n")

        XCTAssertEqual(KeybindConflict.all(in: config), [])
    }

    // MARK: what each answer writes

    func test_accept_writesTheUnsetAndLeavesTheLineThatTookIt() throws {
        let config = try load("keybind = split_vertical=cmd+shift+p\n")
        let conflict = KeybindConflict.all(in: config)[0]

        let text = try write(conflict.accepting(KeymapOverrides(config: config)))

        XCTAssertTrue(text.contains("keybind = toggle_command_palette=none"), text)
        XCTAssertTrue(text.contains("keybind = split_vertical=cmd+shift+p"), text)
        let reloaded = ConfigLoader.loadGeneralConfig(configRoot: tempRoot)
        XCTAssertEqual(KeybindConflict.all(in: reloaded), [], "and it stops being reported")
    }

    /// Revert backs out both halves at once, which is the whole point: the line goes, so the chord
    /// returns to the action that shipped with it and the winner returns to its own default.
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

    /// Answering one leaves the others alone, or a three-conflict config would be settled by the
    /// first card the user happened to press.
    func test_acceptingOne_leavesTheOthersReported() throws {
        let config = try load(
            """
            float = order:1 title:lazygit command:lazygit key:cmd+g
            float = order:2 title:nvim command:nvim key:cmd+e
            """)
        let viewer = try XCTUnwrap(
            KeybindConflict.all(in: config).first { $0.loser == .openDiffViewer })

        _ = try write(viewer.accepting(KeymapOverrides(config: config)))

        let reloaded = ConfigLoader.loadGeneralConfig(configRoot: tempRoot)
        XCTAssertEqual(KeybindConflict.all(in: reloaded).map(\.loser), [.searchSelection])
    }

    /// Floats bind before user keybinds, so a `keybind =` line can take a float's chord and leave
    /// the float as the loser. Accept would emit `toggle_float:<id>=none`, which the assembler
    /// refuses by design, so the line sat inert and the card came back at every launch looking as
    /// though it had been answered.
    func test_aFloatAsTheLoser_cannotBeAccepted() throws {
        let config = try load("float = title:lazygit command:lazygit key:cmd+y\nkeybind = new_tab=cmd+y\n")

        let conflict = try XCTUnwrap(KeybindConflict.all(in: config).first)

        XCTAssertEqual(conflict.winner, .newTab)
        XCTAssertFalse(conflict.isAcceptable, "there is no line Accept could write that survives")
        XCTAssertTrue(conflict.isRevertable, "but the keybind line that took it can go")
    }

    /// Neither answer applies, so there is nothing to put on a card. Two floats on one chord is a
    /// config error the shared notice covers, not a question with buttons.
    func test_aConflictWithNoAnswer_isNotReported() throws {
        let config = try load(
            "float = order:1 title:a command:a key:cmd+y\nfloat = order:2 title:b command:b key:cmd+y\n")

        XCTAssertEqual(KeybindConflict.all(in: config), [])
    }

    /// Revert used to write the winner's default chord in, and `binds` is keyed by chord, so it
    /// evicted whatever else held it. Here `new_tab` sits on ⌘F, which is `toggle_search`'s default;
    /// reverting the palette's conflict must not cost the user their New Tab line.
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

    /// One standing fact, one sentence. The card and the Shortcuts row describe the same thing, and
    /// two phrasings of it read as two different problems.
    func test_theCardAndTheRow_useTheSameSentence() throws {
        let config = try load("keybind = split_vertical=cmd+shift+p\n")
        let conflict = try XCTUnwrap(KeybindConflict.all(in: config).first)

        let rowMessage = config.configDiagnostics.first { $0.scope == .keybind(.toggleCommandPalette) }?
            .message
        XCTAssertEqual(conflict.message, rowMessage)
    }

    /// Reverting a keybind line must not touch a float line, which the writer does not own.
    func test_revert_leavesFloatLinesAlone() throws {
        let config = try load(
            "float = title:lazygit command:lazygit key:cmd+shift+j\nkeybind = split_vertical=cmd+shift+p\n")
        let conflict = try XCTUnwrap(KeybindConflict.all(in: config).first { $0.isRevertable })

        let text = try write(conflict.reverting(KeymapOverrides(config: config)))

        XCTAssertTrue(text.contains("float = title:lazygit command:lazygit key:cmd+shift+j"), text)
    }
}
