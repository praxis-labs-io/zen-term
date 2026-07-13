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
        try seed("float = id:dev command:\"npm run dev\" key:cmd+shift+d\n", in: dir)
        var desired = KeymapDefaults.map.filter { $0.value != .toggleZoom }
        desired[Chord(command: true, shift: true, key: "z")] = .toggleZoom
        try ConfigWriter.apply(keybinds: desired, configRoot: dir)
        let text = try read(dir)
        XCTAssertTrue(text.contains("float = id:dev command:\"npm run dev\" key:cmd+shift+d"), text)
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

    private func float(
        id: String, title: String? = nil, icon: String = ToolFloatParser.defaultIcon,
        command: String, width: CGFloat = 0.85, height: CGFloat = 0.85, git: Bool = false, toggle: Chord
    ) -> ToolFloat {
        ToolFloat(
            id: id, title: title ?? "Open \(id)", icon: icon, command: command,
            widthFraction: width, heightFraction: height, requiresGitRepo: git, emptyGuard: nil, toggle: toggle)
    }

    func test_float_serialize_roundTripsThroughParser() throws {
        let original = float(
            id: "gitdash", title: "Open GitDash", icon: "chart.bar", command: "npm run dev",
            width: 0.9, height: 0.8, git: true, toggle: Chord(command: true, shift: true, key: "g"))
        let line = ConfigWriter.serializeFloat(original)
        let value = String(line.dropFirst("float = ".count))
        XCTAssertEqual(ToolFloatParser.parse(value), original)
    }

    func test_float_serialize_omitsDefaultFields() throws {
        let lean = float(id: "dev", command: "vim", toggle: Chord(command: true, shift: true, key: "d"))
        XCTAssertEqual(ConfigWriter.serializeFloat(lean), "float = id:dev key:cmd+shift+d command:vim")
    }

    func test_float_upsert_appendsWhenAbsent() throws {
        let dir = try makeTempDir()
        try seed("theme = x\n", in: dir)
        try ConfigWriter.apply(
            floatUpserts: [float(id: "dev", command: "vim", toggle: Chord(command: true, shift: true, key: "d"))],
            configRoot: dir)
        XCTAssertEqual(try read(dir), "theme = x\nfloat = id:dev key:cmd+shift+d command:vim\n")
    }

    func test_float_upsert_replacesByIDPreservingComment() throws {
        let dir = try makeTempDir()
        try seed("float = id:dev command:old key:cmd+shift+d  # my dev float\n", in: dir)
        try ConfigWriter.apply(
            floatUpserts: [float(id: "dev", command: "new", toggle: Chord(command: true, shift: true, key: "d"))],
            configRoot: dir)
        XCTAssertEqual(try read(dir), "float = id:dev key:cmd+shift+d command:new  # my dev float\n")
    }

    func test_float_removal_deletesByIDLeavingOthers() throws {
        let dir = try makeTempDir()
        try seed(
            "# tools\nfloat = id:dev command:vim key:cmd+shift+d\nfloat = id:top command:htop key:cmd+shift+t\n",
            in: dir)
        try ConfigWriter.apply(floatRemovals: ["dev"], configRoot: dir)
        XCTAssertEqual(try read(dir), "# tools\nfloat = id:top command:htop key:cmd+shift+t\n")
    }

    func test_float_roundTripsThroughLoader() throws {
        let dir = try makeTempDir()
        try ConfigWriter.apply(
            floatUpserts: [
                float(id: "dev", command: "npm run dev", toggle: Chord(command: true, shift: true, key: "d"))
            ], configRoot: dir)
        let floats = ConfigLoader.loadGeneralConfig(configRoot: dir).floats
        XCTAssertEqual(floats.count, 1)
        XCTAssertEqual(floats.first?.id, "dev")
        XCTAssertEqual(floats.first?.command, "npm run dev")
        XCTAssertEqual(floats.first?.toggle, Chord(command: true, shift: true, key: "d"))
    }

    func test_float_quotesHashInCommand_survivesParse() throws {
        let original = float(
            id: "note", command: "echo #1", toggle: Chord(command: true, shift: true, key: "n"))
        let line = ConfigWriter.serializeFloat(original)
        XCTAssertTrue(line.contains("command:\"echo #1\""), line)
        // The whole line must survive the parser's comment strip (the `#` is inside quotes).
        let stripped = ConfigText.stripComment(line)
        XCTAssertEqual(ToolFloatParser.parse(String(stripped.dropFirst("float = ".count))), original)
    }

    func test_keybind_narrowingMultiDefaultAction_persistsAndRoundTrips() throws {
        let dir = try makeTempDir()
        // splitVertical ships bound to BOTH ⌘⇧| and ⌘⇧\. Narrow it to just ⌘⇧\ — a chord that
        // happens to be one of its own defaults. A per-chord diff emits no line and lets the
        // assembler restore both; the per-action diff must write the one surviving chord.
        var desired = KeymapDefaults.map.filter { $0.value != .splitVertical }
        desired[Chord(command: true, shift: true, key: "\\")] = .splitVertical
        try ConfigWriter.apply(keybinds: desired, configRoot: dir)
        let text = try read(dir)
        XCTAssertTrue(text.contains("keybind = split_vertical=cmd+shift+\\"), text)
        let keymap = ConfigLoader.loadGeneralConfig(configRoot: dir).keymap
        XCTAssertEqual(keymap[Chord(command: true, shift: true, key: "\\")], .splitVertical)
        XCTAssertNil(keymap[Chord(command: true, shift: true, key: "|")])  // the dropped default is gone
    }
}
