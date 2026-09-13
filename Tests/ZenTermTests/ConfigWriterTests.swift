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
        XCTAssertEqual(try Data(contentsOf: url), garbage)
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
        XCTAssertEqual(attrs[.type] as? FileAttributeType, .typeSymbolicLink)
        XCTAssertEqual(try String(contentsOf: realFile, encoding: .utf8), "theme = new\n")
    }

    func test_keybind_emitsOnlyNonDefaultOverrides() throws {
        let dir = try makeTempDir()
        try seed("# ─── Keybinds ───\n", in: dir)
        var desired = KeymapOverrides(binds: KeymapDefaults.map)
        desired.bind(.toggleCommandPalette, to: [Chord(command: true, shift: true, key: "o")])
        try ConfigWriter.apply(keybinds: desired, configRoot: dir)
        let text = try read(dir)
        XCTAssertTrue(text.contains("keybind = toggle_command_palette=cmd+shift+o"), text)
        XCTAssertEqual(text.components(separatedBy: "\n").filter { $0.hasPrefix("keybind = ") }.count, 1)
    }

    func test_keybind_resetAll_removesReservedKeybindLines() throws {
        let dir = try makeTempDir()
        try seed("theme = x\nkeybind = toggle_zoom=cmd+shift+z\n", in: dir)
        try ConfigWriter.apply(
            keybinds: KeymapOverrides(binds: KeymapDefaults.map), configRoot: dir)
        let text = try read(dir)
        XCTAssertFalse(text.contains("keybind = "), text)
        XCTAssertTrue(text.contains("theme = x"), text)
    }

    func test_keybind_preservesFloatKeybindLines() throws {
        let dir = try makeTempDir()
        try seed("keybind = toggle_float:dev=cmd+shift+d\nkeybind = toggle_zoom=cmd+shift+z\n", in: dir)
        try ConfigWriter.apply(
            keybinds: KeymapOverrides(binds: KeymapDefaults.map), configRoot: dir)
        let text = try read(dir)
        XCTAssertTrue(text.contains("keybind = toggle_float:dev=cmd+shift+d"), text)
        XCTAssertFalse(text.contains("toggle_zoom"), text)
    }

    func test_keybind_leavesFloatDefinitionLinesUntouched() throws {
        let dir = try makeTempDir()
        try seed("float = title:dev command:\"npm run dev\" key:cmd+shift+d\n", in: dir)
        var desired = KeymapOverrides(binds: KeymapDefaults.map)
        desired.bind(.toggleZoom, to: [Chord(command: true, shift: true, key: "z")])
        try ConfigWriter.apply(keybinds: desired, configRoot: dir)
        let text = try read(dir)
        XCTAssertTrue(text.contains("float = title:dev command:\"npm run dev\" key:cmd+shift+d"), text)
    }

    func test_keybind_unboundAction_emitsANoneLine() throws {
        let dir = try makeTempDir()
        var desired = KeymapOverrides(binds: KeymapDefaults.map)
        desired.unbind(.findNext)
        try ConfigWriter.apply(keybinds: desired, configRoot: dir)
        let text = try read(dir)
        XCTAssertTrue(text.contains("keybind = search_next=none"), text)
        XCTAssertEqual(text.components(separatedBy: "\n").filter { $0.hasPrefix("keybind = ") }.count, 1)
    }

    func test_keybind_unboundAction_survivesAReadAndRewrite() throws {
        let dir = try makeTempDir()
        var desired = KeymapOverrides(binds: KeymapDefaults.map)
        desired.unbind(.findNext)
        try ConfigWriter.apply(keybinds: desired, configRoot: dir)

        let reloaded = ConfigLoader.loadGeneralConfig(configRoot: dir)
        XCTAssertEqual(reloaded.unboundActions, [.findNext])
        XCTAssertFalse(reloaded.keymap.values.contains(.findNext))
        try ConfigWriter.apply(
            keybinds: KeymapOverrides(binds: reloaded.keymap, unbound: reloaded.unboundActions),
            configRoot: dir)

        let rewritten = try read(dir)
        XCTAssertTrue(rewritten.contains("keybind = search_next=none"), rewritten)
    }

    func test_keybind_rebindingOneAction_leavesAnotherActionsUnbindOnDisk() throws {
        let dir = try makeTempDir()
        try seed("keybind = find_next=none\n", in: dir)
        let loaded = ConfigLoader.loadGeneralConfig(configRoot: dir)

        var desired = KeymapOverrides(binds: loaded.keymap, unbound: loaded.unboundActions)
        desired.bind(.splitVertical, to: [Chord(command: true, shift: true, key: "u")])
        try ConfigWriter.apply(keybinds: desired, configRoot: dir)

        let text = try read(dir)
        XCTAssertTrue(text.contains("keybind = split_vertical=cmd+shift+u"), text)
        XCTAssertTrue(text.contains("keybind = search_next=none"), text)
    }

    func test_keybind_bindingAnUnboundActionBack_dropsTheNoneLine() throws {
        let dir = try makeTempDir()
        try seed("keybind = clear_screen=none\n", in: dir)
        let loaded = ConfigLoader.loadGeneralConfig(configRoot: dir)

        var desired = KeymapOverrides(binds: loaded.keymap, unbound: loaded.unboundActions)
        desired.bind(.clearScreen, to: [Chord(command: true, key: "k")])
        try ConfigWriter.apply(keybinds: desired, configRoot: dir)

        let text = try read(dir)
        XCTAssertFalse(text.contains("clear_screen"), text)
        XCTAssertEqual(
            ConfigLoader.loadGeneralConfig(configRoot: dir).keymap[Chord(command: true, key: "k")],
            .clearScreen)
    }

    func test_keybind_roundTripsThroughAssembler() throws {
        let dir = try makeTempDir()
        var desired = KeymapOverrides(binds: KeymapDefaults.map)
        desired.bind(.toggleZoom, to: [Chord(command: true, shift: true, key: "z")])
        try ConfigWriter.apply(keybinds: desired, configRoot: dir)
        let keymap = ConfigLoader.loadGeneralConfig(configRoot: dir).keymap
        XCTAssertEqual(keymap[Chord(command: true, shift: true, key: "z")], .toggleZoom)
        XCTAssertNil(keymap[Chord(command: true, shift: true, key: "⏎")])
    }

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

    func test_float_serialize_emitsToolbarFalse_andRoundTrips() throws {
        var hidden = float(title: "dev", command: "vim", toggle: Chord(command: true, shift: true, key: "d"))
        hidden.showsInToolbar = false
        let line = ConfigWriter.serializeFloat(hidden)
        XCTAssertEqual(line, "float = order:1 title:dev key:cmd+shift+d command:vim toolbar:false")
        XCTAssertEqual(ToolFloatParser.parse(String(line.dropFirst("float = ".count))), hidden)
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
        let renamed = float(title: "devbox", command: "vim", toggle: Chord(command: true, shift: true, key: "d"))
        try ConfigWriter.apply(floatUpserts: [renamed], floatRemovals: ["dev"], configRoot: dir)
        XCTAssertEqual(
            ConfigLoader.loadGeneralConfig(configRoot: dir).floats.map(\.id), ["devbox"],
            "the rename drops the old id, leaving exactly one float — not a duplicate")
    }

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

    func test_floatOrder_stampsEveryFloat_evenWhenNoneHadOrder() throws {
        let dir = try makeTempDir()
        try seed(
            """
            float = title:a command:a key:cmd+shift+a
            float = title:b command:b key:cmd+shift+b

            """, in: dir)
        let loaded = ConfigLoader.loadGeneralConfig(configRoot: dir).floats

        try ConfigWriter.applyFloatOrder(loaded, configRoot: dir)

        let text = try read(dir)
        XCTAssertTrue(text.contains("float = order:1 title:a"), text)
        XCTAssertTrue(text.contains("float = order:2 title:b"), text)
    }

    func test_float_rename_keepsItsPositionInTheDock() throws {
        let dir = try makeTempDir()
        try seed(
            """
            float = title:a command:a key:cmd+shift+a
            float = title:b command:b key:cmd+shift+b
            float = title:c command:c key:cmd+shift+c

            """, in: dir)
        let loaded = ConfigLoader.loadGeneralConfig(configRoot: dir).floats
        XCTAssertEqual(loaded.map(\.id), ["a", "b", "c"])

        let renamed = float(
            title: "a2", order: loaded[0].order, command: "a",
            toggle: Chord(command: true, shift: true, key: "a"))
        try ConfigWriter.apply(floatUpserts: [renamed], floatRemovals: ["a"], configRoot: dir)

        XCTAssertEqual(
            ConfigLoader.loadGeneralConfig(configRoot: dir).floats.map(\.id), ["a2", "b", "c"],
            "renaming a float must not move it")
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

    func test_serializeFloat_dirUnderHome_abbreviatesToTilde_andRoundTrips() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = URL(fileURLWithPath: home.path + "/notes").standardizedFileURL
        let original = float(
            title: "notes", command: "vim", dir: dir, toggle: Chord(command: true, shift: true, key: "n"))

        let line = ConfigWriter.serializeFloat(original)
        XCTAssertTrue(line.contains("dir:~/notes"), line)

        let value = String(line.dropFirst("float = ".count))
        XCTAssertEqual(ToolFloatParser.parse(value), original)
    }

    func test_serializeFloat_dirOutsideHome_roundTripsUnchanged() throws {
        let dir = URL(fileURLWithPath: "/tmp/x").standardizedFileURL
        let original = float(
            title: "tmp", command: "vim", dir: dir, toggle: Chord(command: true, shift: true, key: "t"))

        let line = ConfigWriter.serializeFloat(original)
        XCTAssertTrue(line.contains("dir:/tmp/x"), line)

        let value = String(line.dropFirst("float = ".count))
        XCTAssertEqual(ToolFloatParser.parse(value), original)
    }

    func test_keybind_narrowingMultiChordAction_persistsAndRoundTrips() throws {
        let dir = try makeTempDir()
        XCTAssertNil(
            KeymapDefaults.map[Chord(command: true, shift: true, key: "u")],
            "a default claimed the fixture's extra chord; move the fixture to a free one")
        var desired = KeymapOverrides(binds: KeymapDefaults.map)
        desired.bind(
            .splitVertical,
            to: [
                Chord(command: true, shift: true, key: "\\"),
                Chord(command: true, shift: true, key: "u"),
            ])
        try ConfigWriter.apply(keybinds: desired, configRoot: dir)
        var text = try read(dir)
        XCTAssertTrue(text.contains("keybind = split_vertical=cmd+shift+\\"), text)
        XCTAssertTrue(text.contains("keybind = split_vertical=cmd+shift+u"), text)
        XCTAssertEqual(
            ConfigLoader.loadGeneralConfig(configRoot: dir).keymap[Chord(command: true, shift: true, key: "u")],
            .splitVertical)

        desired.bind(.splitVertical, to: [Chord(command: true, shift: true, key: "\\")])
        try ConfigWriter.apply(keybinds: desired, configRoot: dir)
        text = try read(dir)
        XCTAssertFalse(text.contains("split_vertical=cmd+shift+u"), text)
        let keymap = ConfigLoader.loadGeneralConfig(configRoot: dir).keymap
        XCTAssertEqual(keymap[Chord(command: true, shift: true, key: "\\")], .splitVertical)
        XCTAssertNil(keymap[Chord(command: true, shift: true, key: "u")])
    }
}
