import AppKit
import XCTest

@testable import ZenTerm

/// The built-in Scratch float against the config file.
///
/// A built-in float sits in two places a user float never does: the per-action keybind diff, which
/// emits its rebind, and `applyKeybinds`' verbatim preservation of `toggle_float:` lines, which is
/// there for user floats. Belonging to both is what duplicates its line, and nothing else in the
/// suite writes twice in a row, which is why that case is here.
final class ScratchFloatTests: XCTestCase {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenterm-scratch-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func read(_ dir: URL) throws -> String {
        try String(contentsOf: dir.appendingPathComponent("config"), encoding: .utf8)
    }

    private func scratchLines(_ text: String) -> [String] {
        text.split(separator: "\n").map(String.init).filter { $0.contains("toggle_float:scratch") }
    }

    // MARK: the spec

    func test_scratchLaunchesAShellRatherThanACommand() {
        // The empty command is what `ToolFloatController.spawn` branches on. A `float =` line can
        // never produce it, since `command:` is required there.
        XCTAssertTrue(ToolFloat.scratch.command.isEmpty)
        XCTAssertEqual(ToolFloat.scratch.persist, .window)
    }

    /// The two axes together: one instance per tab (`scope`), and it survives a dismissal
    /// (`persist`). Scratch is the only float that gets a tab.
    func test_scratchIsScopedToTheTab() {
        XCTAssertEqual(ToolFloat.scratch.scope, .tab)
    }

    /// The axis is Swift's, not the config's. `persist:tab` was cut after daily driving, and a
    /// `float =` line must have no way to reach tab scope — no key, and no token that backs into it.
    func test_aConfiguredFloat_cannotReachTabScope() {
        let float = ToolFloatParser.parse("title:x command:c key:cmd+shift+j scope:tab persist:tab")
        XCTAssertEqual(float?.scope, .window)
    }

    /// The one thing a mistyped glyph fails at, and nothing else would catch it. Resolved the way
    /// the dock resolves it, so a composed or brand-mark icon counts as rendering too — asserting
    /// `systemSymbolName` directly only ever accepted a plain SF Symbol.
    func test_scratchIcon_resolves() {
        XCTAssertNotNil(IconCatalog.image(ToolFloat.scratch.icon))
    }

    // MARK: the config file

    func test_atItsDefault_scratchWritesNoLine() throws {
        let dir = try makeTempDir()
        try ConfigWriter.apply(keybinds: KeymapOverrides(defaults: KeymapDefaults.map), configRoot: dir)

        XCTAssertEqual(scratchLines(try read(dir)), [])
        XCTAssertFalse(try read(dir).contains("float ="), "the built-in is never a float line")
    }

    /// The duplicate-line trap. `applyKeybinds` preserves every `toggle_float:` line verbatim AND
    /// emits the diff; without the built-in's exclusion from the first half, each write appends
    /// another copy and a rebind strands the old line above the new one.
    func test_rebindingScratch_writesOneLine_andASecondWriteDoesNotDuplicateIt() throws {
        let dir = try makeTempDir()
        var overrides = KeymapOverrides(defaults: KeymapDefaults.map)
        overrides.bind(.toggleToolFloat("scratch"), to: [Chord(command: true, key: "y")])

        try ConfigWriter.apply(keybinds: overrides, configRoot: dir)
        XCTAssertEqual(scratchLines(try read(dir)), ["keybind = toggle_float:scratch=cmd+y"])

        try ConfigWriter.apply(keybinds: overrides, configRoot: dir)
        XCTAssertEqual(
            scratchLines(try read(dir)), ["keybind = toggle_float:scratch=cmd+y"],
            "a second write must not append another copy")
    }

    /// A user float's line still rides through untouched: the exclusion is by id, not by shape.
    func test_aUserFloatsKeybindLineIsStillPreserved() throws {
        let dir = try makeTempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "keybind = toggle_float:btop=cmd+shift+b\n"
            .write(to: dir.appendingPathComponent("config"), atomically: true, encoding: .utf8)

        try ConfigWriter.apply(keybinds: KeymapOverrides(defaults: KeymapDefaults.map), configRoot: dir)

        XCTAssertTrue(try read(dir).contains("keybind = toggle_float:btop=cmd+shift+b"))
    }

    /// Round-trip the unbind: written by the writer, honored by the parser, and back in the set the
    /// next write regenerates from, so it survives an unrelated Shortcuts edit.
    func test_unbindingScratch_roundTripsThroughTheFile() throws {
        let dir = try makeTempDir()
        var overrides = KeymapOverrides(defaults: KeymapDefaults.map)
        overrides.unbind(.toggleToolFloat("scratch"))
        try ConfigWriter.apply(keybinds: overrides, configRoot: dir)
        XCTAssertEqual(scratchLines(try read(dir)), ["keybind = toggle_float:scratch=none"])

        let parsed = GeneralConfigParser.parse(try read(dir), fallback: .builtIn)

        XCTAssertNil(parsed.keymap[Chord(command: true, key: ";")])
        XCTAssertTrue(parsed.unboundActions.contains(.toggleToolFloat("scratch")))
        XCTAssertEqual(
            KeymapOverrides(config: parsed).unbound, [.toggleToolFloat("scratch")],
            "the next write must still know the unbind was deliberate")
    }

    // MARK: the reserved id

    func test_aUserFloatNamedScratch_isRefused_andTheBuiltInSurvives() {
        let parsed = GeneralConfigParser.parse(
            "float = title:Scratch command:\"echo hi\" key:cmd+shift+y\n", fallback: .builtIn)

        XCTAssertTrue(parsed.floats.isEmpty, "the line must not shadow the built-in")
        XCTAssertEqual(
            parsed.configDiagnostics.map(\.problem), [.floatReservedID("scratch")])
        XCTAssertEqual(parsed.configDiagnostics.first?.scope, .toolFloat(label: "Scratch"))
    }

    func test_aUserFloatWithADifferentName_isUnaffected() {
        let parsed = GeneralConfigParser.parse(
            "float = title:\"Scratch Pad\" command:\"echo hi\" key:cmd+shift+y\n", fallback: .builtIn)

        XCTAssertEqual(parsed.floats.map(\.id), ["scratch-pad"])
        XCTAssertEqual(parsed.configDiagnostics, [])
    }
}
