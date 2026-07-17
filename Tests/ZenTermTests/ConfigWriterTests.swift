import XCTest

@testable import ZenTerm

final class ConfigWriterTests: XCTestCase {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenterm-config-writer-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func seed(_ text: String, in dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try text.write(to: dir.appendingPathComponent("config"), atomically: true, encoding: .utf8)
    }

    private func read(_ dir: URL) throws -> String {
        try String(contentsOf: dir.appendingPathComponent("config"), encoding: .utf8)
    }

    func test_scalarSet_replacesActiveValue_preservingTrailingComment() throws {
        let dir = try makeTempDir()
        try seed("font-size = 14   # points; clamped to 6…72\n", in: dir)
        try ConfigWriter.apply(scalars: ["font-size": "15"], configRoot: dir)
        XCTAssertEqual(try read(dir), "font-size = 15  # points; clamped to 6…72\n")
    }

    func test_scalarSet_insertsAfterCommentedDefault() throws {
        let dir = try makeTempDir()
        try seed("# Terminal\n# font-size = 14   # points\n", in: dir)
        try ConfigWriter.apply(scalars: ["font-size": "18"], configRoot: dir)
        XCTAssertEqual(try read(dir), "# Terminal\n# font-size = 14   # points\nfont-size = 18\n")
    }

    func test_scalarSet_appendsWhenAbsent() throws {
        let dir = try makeTempDir()
        try seed("# just a comment\n", in: dir)
        try ConfigWriter.apply(scalars: ["theme": "gruvbox"], configRoot: dir)
        XCTAssertEqual(try read(dir), "# just a comment\ntheme = gruvbox\n")
    }

    func test_scalarSet_createsFileWhenAbsent() throws {
        let dir = try makeTempDir()
        try ConfigWriter.apply(scalars: ["theme": "gruvbox"], configRoot: dir)
        XCTAssertEqual(try read(dir), "theme = gruvbox\n")
    }

    func test_removal_deletesActiveLine() throws {
        let dir = try makeTempDir()
        try seed("# font-size = 14\nfont-size = 20\ntheme = gruvbox\n", in: dir)
        try ConfigWriter.apply(removals: ["font-size"], configRoot: dir)
        XCTAssertEqual(try read(dir), "# font-size = 14\ntheme = gruvbox\n")
    }

    func test_preservesUnknownKeysAndBlankLines() throws {
        let dir = try makeTempDir()
        let original = "# header\n\nunknown-key = keepme\n\ntheme = old\n"
        try seed(original, in: dir)
        try ConfigWriter.apply(scalars: ["theme": "new"], configRoot: dir)
        XCTAssertEqual(try read(dir), "# header\n\nunknown-key = keepme\n\ntheme = new\n")
    }

    func test_roundTripsThroughParser() throws {
        let dir = try makeTempDir()
        try seed("# comment\n", in: dir)
        try ConfigWriter.apply(scalars: ["font-size": "16", "backdrop-alpha": "0.5"], configRoot: dir)
        let parsed = ConfigLoader.loadGeneralConfig(configRoot: dir)
        XCTAssertEqual(parsed.fontSize, 16)
        XCTAssertEqual(parsed.backdropAlpha, 0.5)
    }

    func test_unreadableExistingFile_throwsWithoutClobbering() throws {
        let dir = try makeTempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("config")
        let garbage = Data([0xFF, 0xFE, 0xFF])
        try garbage.write(to: url)
        XCTAssertThrowsError(try ConfigWriter.apply(scalars: ["theme": "x"], configRoot: dir))
        XCTAssertEqual(try Data(contentsOf: url), garbage)  // byte-identical: not clobbered
    }

    func test_writesThroughSymlink() throws {
        let dir = try makeTempDir()
        let target = try makeTempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let realFile = target.appendingPathComponent("real-config")
        try "theme = old\n".write(to: realFile, atomically: true, encoding: .utf8)
        let link = dir.appendingPathComponent("config")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: realFile)

        try ConfigWriter.apply(scalars: ["theme": "new"], configRoot: dir)

        let attrs = try FileManager.default.attributesOfItem(atPath: link.path)
        XCTAssertEqual(attrs[.type] as? FileAttributeType, .typeSymbolicLink)  // link intact
        XCTAssertEqual(try String(contentsOf: realFile, encoding: .utf8), "theme = new\n")  // wrote target
    }

    func test_keybind_emitsOnlyNonDefaultOverrides() throws {
        let dir = try makeTempDir()
        try seed("# ─── Keybinds ───\n", in: dir)
        // Move the command palette to cmd+shift+o; keep everything else at its default.
        var desired = KeymapDefaults.map
        desired = desired.filter { $0.value != .toggleCommandPalette }  // drop its default chord
        desired[Chord(command: true, shift: true, key: "o")] = .toggleCommandPalette
        try ConfigWriter.apply(keybinds: desired, configRoot: dir)
        let text = try read(dir)
        XCTAssertTrue(text.contains("keybind = toggle_command_palette=cmd+shift+o"), text)
        // No other action changed → exactly one keybind line.
        XCTAssertEqual(text.components(separatedBy: "\n").filter { $0.hasPrefix("keybind = ") }.count, 1)
    }

    func test_keybind_resetAll_removesReservedKeybindLines() throws {
        let dir = try makeTempDir()
        try seed("theme = x\nkeybind = toggle_zoom=cmd+shift+z\n", in: dir)
        try ConfigWriter.apply(keybinds: KeymapDefaults.map, configRoot: dir)  // all defaults → no overrides
        let text = try read(dir)
        XCTAssertFalse(text.contains("keybind = "), text)
        XCTAssertTrue(text.contains("theme = x"), text)
    }

    func test_keybind_preservesFloatKeybindLines() throws {
        let dir = try makeTempDir()
        try seed("keybind = toggle_float:dev=cmd+shift+d\nkeybind = toggle_zoom=cmd+shift+z\n", in: dir)
        try ConfigWriter.apply(keybinds: KeymapDefaults.map, configRoot: dir)  // reset reserved to defaults
        let text = try read(dir)
        XCTAssertTrue(text.contains("keybind = toggle_float:dev=cmd+shift+d"), text)  // float bind kept
        XCTAssertFalse(text.contains("toggle_zoom"), text)  // reserved override dropped
    }

    func test_keybind_leavesFloatDefinitionLinesUntouched() throws {
        let dir = try makeTempDir()
        try seed("float = title:dev command:\"npm run dev\" key:cmd+shift+d\n", in: dir)
        var desired = KeymapDefaults.map.filter { $0.value != .toggleZoom }
        desired[Chord(command: true, shift: true, key: "z")] = .toggleZoom
        try ConfigWriter.apply(keybinds: desired, configRoot: dir)
        let text = try read(dir)
        XCTAssertTrue(text.contains("float = title:dev command:\"npm run dev\" key:cmd+shift+d"), text)
    }

    func test_keybind_roundTripsThroughAssembler() throws {
        let dir = try makeTempDir()
        var desired = KeymapDefaults.map.filter { $0.value != .toggleZoom }
        desired[Chord(command: true, shift: true, key: "z")] = .toggleZoom
        try ConfigWriter.apply(keybinds: desired, configRoot: dir)
        let keymap = ConfigLoader.loadGeneralConfig(configRoot: dir).keymap
        XCTAssertEqual(keymap[Chord(command: true, shift: true, key: "z")], .toggleZoom)
        XCTAssertNil(keymap[Chord(command: true, key: "f")])  // old ⌘F default was dropped
    }

    // MARK: floats

    /// A float built the way the config produces one: the id is always `slug(title)`, never authored
    /// beside it — so a test can't assert a float the parser could never hand back.
    private func float(
        title: String, order: Int = 1, icon: String = ToolFloatParser.defaultIcon,
        command: String, dir: URL? = nil, width: CGFloat = 0.85, height: CGFloat = 0.85,
        git: Bool = false, persist: ToolFloat.Persistence = .ephemeral, toggle: Chord
    ) -> ToolFloat {
        ToolFloat(
            id: ToolFloatParser.slug(forTitle: title), order: order, title: title, icon: icon,
            command: command, dir: dir, widthFraction: width, heightFraction: height,
            requiresGitRepo: git, persist: persist, toggle: toggle)
    }

    func test_float_serialize_roundTripsThroughParser() throws {
        let original = float(
            title: "Open GitDash", icon: "chart.bar", command: "npm run dev",
            width: 0.9, height: 0.8, git: true, toggle: Chord(command: true, shift: true, key: "g"))
        let line = ConfigWriter.serializeFloat(original)
        let value = String(line.dropFirst("float = ".count))
        XCTAssertEqual(ToolFloatParser.parse(value), original)
    }

    func test_float_serialize_omitsDefaultFields() throws {
        let lean = float(title: "dev", command: "vim", toggle: Chord(command: true, shift: true, key: "d"))
        XCTAssertEqual(
            ConfigWriter.serializeFloat(lean), "float = order:1 title:dev key:cmd+shift+d command:vim")
    }

    func test_float_upsert_appendsWhenAbsent() throws {
        let dir = try makeTempDir()
        try seed("theme = x\n", in: dir)
        try ConfigWriter.apply(
            floatUpserts: [float(title: "dev", command: "vim", toggle: Chord(command: true, shift: true, key: "d"))],
            configRoot: dir)
        XCTAssertEqual(try read(dir), "theme = x\nfloat = order:1 title:dev key:cmd+shift+d command:vim\n")
    }

    func test_float_upsert_replacesByIDPreservingComment() throws {
        let dir = try makeTempDir()
        try seed("float = order:1 title:dev command:old key:cmd+shift+d  # my dev float\n", in: dir)
        try ConfigWriter.apply(
            floatUpserts: [float(title: "dev", command: "new", toggle: Chord(command: true, shift: true, key: "d"))],
            configRoot: dir)
        XCTAssertEqual(
            try read(dir), "float = order:1 title:dev key:cmd+shift+d command:new  # my dev float\n")
    }

    func test_float_removal_deletesByIDLeavingOthers() throws {
        let dir = try makeTempDir()
        try seed(
            "# tools\nfloat = title:dev command:vim key:cmd+shift+d\nfloat = title:top command:htop key:cmd+shift+t\n",
            in: dir)
        try ConfigWriter.apply(floatRemovals: ["dev"], configRoot: dir)
        XCTAssertEqual(try read(dir), "# tools\nfloat = title:top command:htop key:cmd+shift+t\n")
    }

    func test_float_upsertWithRemoval_movesFloatToNewTitle() throws {
        let dir = try makeTempDir()
        try seed("float = title:dev command:vim key:cmd+shift+d\n", in: dir)
        // A rename: the new title slugs to a new id, so the float is upserted under that id AND the
        // old line removed in the same write. This is the only path that changes a float's id.
        let renamed = float(title: "devbox", command: "vim", toggle: Chord(command: true, shift: true, key: "d"))
        try ConfigWriter.apply(floatUpserts: [renamed], floatRemovals: ["dev"], configRoot: dir)
        XCTAssertEqual(
            ConfigLoader.loadGeneralConfig(configRoot: dir).floats.map(\.id), ["devbox"],
            "the rename drops the old id, leaving exactly one float — not a duplicate")
    }

    // MARK: float order (ZEN-145)

    /// Reordering only renumbers: every float's line stays exactly where it was, and the comments,
    /// blanks, and unrelated keys around it are untouched. That's the payoff of `order:` being a field
    /// instead of the file's line order — the user's file stays theirs.
    func test_floatOrder_renumbersInPlace_preservingTheFileAround() throws {
        let dir = try makeTempDir()
        try seed(
            """
            # tools

            float = order:1 title:dev command:vim key:cmd+shift+d  # my dev float
            theme = gruvbox
            float = order:2 title:top command:htop key:cmd+shift+t

            """, in: dir)
        let dev = float(title: "dev", command: "vim", toggle: Chord(command: true, shift: true, key: "d"))
        let top = float(title: "top", command: "htop", toggle: Chord(command: true, shift: true, key: "t"))

        try ConfigWriter.applyFloatOrder([top, dev], configRoot: dir)

        XCTAssertEqual(
            try read(dir),
            """
            # tools

            float = order:2 title:dev key:cmd+shift+d command:vim  # my dev float
            theme = gruvbox
            float = order:1 title:top key:cmd+shift+t command:htop

            """)
    }

    /// The order the caller passes is the order that comes back out of the file — the assertion that
    /// makes ⌥↑/⌥↓ mean anything, since the dock re-reads the config rather than the row list.
    func test_floatOrder_roundTripsThroughLoader() throws {
        let dir = try makeTempDir()
        try seed(
            """
            float = title:a command:a key:cmd+shift+a
            float = title:b command:b key:cmd+shift+b
            float = title:c command:c key:cmd+shift+c

            """, in: dir)
        let loaded = ConfigLoader.loadGeneralConfig(configRoot: dir).floats
        XCTAssertEqual(loaded.map(\.id), ["a", "b", "c"])

        try ConfigWriter.applyFloatOrder([loaded[2], loaded[0], loaded[1]], configRoot: dir)

        XCTAssertEqual(ConfigLoader.loadGeneralConfig(configRoot: dir).floats.map(\.id), ["c", "a", "b"])
    }

    /// Stamps *every* float, not just the ones that moved: a config with no `order:` at all becomes a
    /// full contiguous sequence on the first reorder, rather than a mix that sorts half by number and
    /// half by line position.
    func test_floatOrder_stampsEveryFloat_evenWhenNoneHadOrder() throws {
        let dir = try makeTempDir()
        try seed(
            """
            float = title:a command:a key:cmd+shift+a
            float = title:b command:b key:cmd+shift+b

            """, in: dir)
        let loaded = ConfigLoader.loadGeneralConfig(configRoot: dir).floats

        try ConfigWriter.applyFloatOrder(loaded, configRoot: dir)  // same order — still stamps

        let text = try read(dir)
        XCTAssertTrue(text.contains("float = order:1 title:a"), text)
        XCTAssertTrue(text.contains("float = order:2 title:b"), text)
    }

    func test_float_roundTripsThroughLoader() throws {
        let dir = try makeTempDir()
        try ConfigWriter.apply(
            floatUpserts: [
                float(title: "dev", command: "npm run dev", toggle: Chord(command: true, shift: true, key: "d"))
            ], configRoot: dir)
        let floats = ConfigLoader.loadGeneralConfig(configRoot: dir).floats
        XCTAssertEqual(floats.count, 1)
        XCTAssertEqual(floats.first?.id, "dev")
        XCTAssertEqual(floats.first?.command, "npm run dev")
        XCTAssertEqual(floats.first?.toggle, Chord(command: true, shift: true, key: "d"))
    }

    func test_float_quotesHashInCommand_survivesParse() throws {
        let original = float(
            title: "note", command: "echo #1", toggle: Chord(command: true, shift: true, key: "n"))
        let line = ConfigWriter.serializeFloat(original)
        XCTAssertTrue(line.contains("command:\"echo #1\""), line)
        // The whole line must survive the parser's comment strip (the `#` is inside quotes).
        let stripped = ConfigText.stripComment(line)
        XCTAssertEqual(ToolFloatParser.parse(String(stripped.dropFirst("float = ".count))), original)
    }

    func test_serializeFloat_omitsDefaultPersist_andEmitsNonDefault() {
        let lean = float(title: "dev", command: "vim", toggle: Chord(command: true, shift: true, key: "d"))
        XCTAssertEqual(
            ConfigWriter.serializeFloat(lean), "float = order:1 title:dev key:cmd+shift+d command:vim")

        let sticky = float(
            title: "dev", command: "vim", persist: .directory,
            toggle: Chord(command: true, shift: true, key: "d"))
        XCTAssertEqual(
            ConfigWriter.serializeFloat(sticky),
            "float = order:1 title:dev key:cmd+shift+d command:vim persist:dir")
    }

    func test_serializeFloat_persistRoundTripsThroughParser() {
        let original = float(
            title: "Open Lazygit", icon: "git", command: "lazygit", height: 0.78, git: true,
            persist: .directory, toggle: Chord(command: true, key: "g"))
        let line = ConfigWriter.serializeFloat(original)
        XCTAssertEqual(ToolFloatParser.parse(String(line.dropFirst("float = ".count))), original)
    }

    /// The review fix for the bug where `dir:~/notes` was silently rewritten to an absolute path:
    /// `serializeFloat` must abbreviate a home-relative `dir` back to `~`, the same way
    /// `WorkspacesWriter` does for workspace paths, or a synced dotfiles config breaks on every
    /// other machine/username the moment any Settings-form edit rewrites the float's line.
    func test_serializeFloat_dirUnderHome_abbreviatesToTilde_andRoundTrips() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = URL(fileURLWithPath: home.path + "/notes").standardizedFileURL
        let original = float(
            title: "notes", command: "vim", dir: dir, toggle: Chord(command: true, shift: true, key: "n"))

        let line = ConfigWriter.serializeFloat(original)
        XCTAssertTrue(line.contains("dir:~/notes"), line)  // not the expanded absolute path

        let value = String(line.dropFirst("float = ".count))
        XCTAssertEqual(ToolFloatParser.parse(value), original)
    }

    func test_serializeFloat_dirOutsideHome_roundTripsUnchanged() throws {
        let dir = URL(fileURLWithPath: "/tmp/x").standardizedFileURL
        let original = float(
            title: "tmp", command: "vim", dir: dir, toggle: Chord(command: true, shift: true, key: "t"))

        let line = ConfigWriter.serializeFloat(original)
        XCTAssertTrue(line.contains("dir:/tmp/x"), line)  // no home prefix to abbreviate

        let value = String(line.dropFirst("float = ".count))
        XCTAssertEqual(ToolFloatParser.parse(value), original)
    }

    func test_keybind_narrowingMultiChordAction_persistsAndRoundTrips() throws {
        let dir = try makeTempDir()
        // A user can point two chords at one action, then drop one. The per-action diff has to
        // write the whole surviving set, and narrowing back to exactly the defaults must write no
        // line at all — leaving the extra chord behind either way would resurrect a bind the user
        // deleted. (Pre-ZEN-142 splitVertical shipped with two default chords and this guarded
        // that; canonicalization collapsed them to one, so the multi-chord case is now reachable
        // only from config — which is exactly where it still has to hold.)
        var desired = KeymapDefaults.map.filter { $0.value != .splitVertical }
        desired[Chord(command: true, shift: true, key: "\\")] = .splitVertical  // its default
        desired[Chord(command: true, shift: true, key: "v")] = .splitVertical  // plus an extra
        try ConfigWriter.apply(keybinds: desired, configRoot: dir)
        var text = try read(dir)
        XCTAssertTrue(text.contains("keybind = split_vertical=cmd+shift+\\"), text)
        XCTAssertTrue(text.contains("keybind = split_vertical=cmd+shift+v"), text)
        XCTAssertEqual(
            ConfigLoader.loadGeneralConfig(configRoot: dir).keymap[Chord(command: true, shift: true, key: "v")],
            .splitVertical)

        // Narrow back to the default alone: the action's set now equals the defaults, so nothing is
        // written — and the assembler's defaults must stand on their own.
        desired[Chord(command: true, shift: true, key: "v")] = nil
        try ConfigWriter.apply(keybinds: desired, configRoot: dir)
        text = try read(dir)
        XCTAssertFalse(text.contains("split_vertical=cmd+shift+v"), text)
        let keymap = ConfigLoader.loadGeneralConfig(configRoot: dir).keymap
        XCTAssertEqual(keymap[Chord(command: true, shift: true, key: "\\")], .splitVertical)
        XCTAssertNil(keymap[Chord(command: true, shift: true, key: "v")])  // the dropped chord is gone
    }
}
