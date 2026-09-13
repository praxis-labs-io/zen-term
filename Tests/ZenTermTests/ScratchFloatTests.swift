import AppKit
import XCTest

@testable import ZenTerm

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

    func test_scratchLaunchesAShellRatherThanACommand() {
        XCTAssertTrue(ToolFloat.scratch.command.isEmpty)
        XCTAssertEqual(ToolFloat.scratch.persist, .window)
    }

    func test_scratchIsScopedToTheTab() {
        XCTAssertEqual(ToolFloat.scratch.scope, .tab)
    }

    func test_aConfiguredFloat_cannotReachTabScope() {
        let float = ToolFloatParser.parse("title:x command:c key:cmd+shift+j scope:tab persist:tab")
        XCTAssertEqual(float?.scope, .window)
    }

    func test_scratchIcon_resolves() {
        XCTAssertNotNil(IconCatalog.image(ToolFloat.scratch.icon))
    }

    func test_atItsDefault_scratchWritesNoLine() throws {
        let dir = try makeTempDir()
        try ConfigWriter.apply(keybinds: KeymapOverrides(defaults: KeymapDefaults.map), configRoot: dir)

        XCTAssertEqual(scratchLines(try read(dir)), [])
        XCTAssertFalse(try read(dir).contains("float ="), "the built-in is never a float line")
    }

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

    func test_aUserFloatsKeybindLineIsStillPreserved() throws {
        let dir = try makeTempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "keybind = toggle_float:btop=cmd+shift+b\n"
            .write(to: dir.appendingPathComponent("config"), atomically: true, encoding: .utf8)

        try ConfigWriter.apply(keybinds: KeymapOverrides(defaults: KeymapDefaults.map), configRoot: dir)

        XCTAssertTrue(try read(dir).contains("keybind = toggle_float:btop=cmd+shift+b"))
    }

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
