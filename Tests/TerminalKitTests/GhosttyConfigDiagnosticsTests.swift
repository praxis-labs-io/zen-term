import GhosttyKit
import XCTest

@testable import TerminalKit

/// The regression net for the generated-config contract: we write every line of the
/// ghostty config ourselves, so a finalized config built by `GhosttyConfigWriter` must carry
/// zero diagnostics. A diagnostic means libghostty no longer understands a key we emit — the
/// exact failure mode of a pin bump that renames or removes a key, which is otherwise silent.
final class GhosttyConfigDiagnosticsTests: XCTestCase {
    override func setUp() {
        super.setUp()
        // GhosttyApp reads `NSApp.isActive`, and NSApp is nil under swift test until the
        // shared application exists.
        _ = NSApplication.shared
        // ghostty_init must run before any ghostty_config_* call; creating the shared app is
        // the one path that performs it.
        _ = GhosttyApp.shared(theme: nil, behavior: nil)
    }

    /// Proves the reader itself works: a key libghostty does not know must surface as a
    /// diagnostic naming it. Without this, the zero-diagnostics test below could pass because
    /// the reader is broken rather than because the config is clean.
    func test_unknownKey_producesDiagnosticNamingIt() throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        let path = NSTemporaryDirectory() + "zenterm-diagnostics-test-bogus-\(pid)"
        try "definitely-not-a-ghostty-key = 1\n".write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let cfg = try XCTUnwrap(ghostty_config_new())
        defer { ghostty_config_free(cfg) }
        ghostty_config_load_file(cfg, path)
        ghostty_config_finalize(cfg)

        let diagnostics = GhosttyApp.diagnostics(of: cfg)
        XCTAssertFalse(diagnostics.isEmpty)
        XCTAssertTrue(
            diagnostics.contains { $0.contains("definitely-not-a-ghostty-key") },
            "diagnostics did not name the unknown key: \(diagnostics)")
    }

    /// A config exercising every key `GhosttyConfigWriter` can emit (theme, palette, cursor
    /// shape and thickness, shader + animation, background opacity, font size override) must
    /// finalize clean against the pinned libghostty.
    func test_generatedConfig_producesNoDiagnostics() throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        let shaderPath = NSTemporaryDirectory() + "zenterm-diagnostics-test-shader-\(pid).glsl"
        try "void mainImage(out vec4 c, in vec2 p) { c = vec4(0.0); }\n"
            .write(toFile: shaderPath, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: shaderPath) }

        let theme = TerminalTheme(
            fontName: "Menlo",
            fontSize: 13,
            background: TerminalColor(red: 0x19, green: 0x17, blue: 0x24),
            foreground: TerminalColor(red: 0xE0, green: 0xDE, blue: 0xF4),
            cursor: TerminalColor(red: 0xEA, green: 0x9A, blue: 0x97),
            selectionBackground: TerminalColor(red: 0x39, green: 0x35, blue: 0x52),
            ansi: (0..<16).map { TerminalColor(red: UInt8($0), green: UInt8($0), blue: UInt8($0)) },
            // Every optional color is filled: the writer skips a nil one, and a key left out here
            // is a key libghostty never finalizes, which is the whole point of this test.
            selectionForeground: TerminalColor(red: 0xE0, green: 0xDE, blue: 0xF4),
            searchForeground: TerminalColor(red: 0xE0, green: 0xDE, blue: 0xF4),
            searchBackground: TerminalColor(red: 0x55, green: 0x49, blue: 0x68),
            searchSelectedForeground: TerminalColor(red: 0x19, green: 0x17, blue: 0x24),
            searchSelectedBackground: TerminalColor(red: 0xC4, green: 0xA7, blue: 0xE7)
        )
        let behavior = TerminalBehavior(
            cursorStyle: .bar, cursorBlink: false, cursorThickness: 4, optionAsAlt: false,
            cursorShader: shaderPath, backgroundAlpha: 0.7)
        let path = try XCTUnwrap(
            GhosttyConfigWriter.writeConfig(
                for: theme, behavior: behavior, shaderAnimation: .always,
                variant: "diagnostics-test", fontSize: 15))

        let cfg = try XCTUnwrap(ghostty_config_new())
        defer { ghostty_config_free(cfg) }
        ghostty_config_load_file(cfg, path)
        ghostty_config_finalize(cfg)

        XCTAssertEqual(
            GhosttyApp.diagnostics(of: cfg), [],
            "the generated config is ours line for line; a diagnostic means GhosttyConfigWriter "
                + "emits a key this libghostty pin does not understand")
    }
}
