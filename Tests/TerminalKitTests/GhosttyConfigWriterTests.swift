import XCTest

@testable import TerminalKit

final class GhosttyConfigWriterTests: XCTestCase {
    private let theme = TerminalTheme(
        fontName: "JetBrainsMono Nerd Font Mono",
        fontSize: 14,
        background: TerminalColor(red: 0x19, green: 0x17, blue: 0x24),
        foreground: TerminalColor(red: 0xE0, green: 0xDE, blue: 0xF4),
        cursor: TerminalColor(red: 0xEA, green: 0x9A, blue: 0x97),
        selectionBackground: TerminalColor(red: 0x39, green: 0x35, blue: 0x52),
        ansi: (0..<16).map { TerminalColor(red: UInt8($0), green: UInt8($0), blue: UInt8($0)) }
    )

    func test_themeColorsAndFontEmitted() {
        let text = GhosttyConfigWriter.configText(for: theme)
        XCTAssertTrue(text.contains("font-family = JetBrainsMono Nerd Font Mono\n"))
        XCTAssertTrue(text.contains("font-size = 14.0\n"))
        XCTAssertTrue(text.contains("background = #191724\n"))
        XCTAssertTrue(text.contains("foreground = #e0def4\n"))
        XCTAssertTrue(text.contains("cursor-color = #ea9a97\n"))
        XCTAssertTrue(text.contains("selection-background = #393552\n"))
    }

    func test_all16PaletteEntriesEmitted() {
        let text = GhosttyConfigWriter.configText(for: theme)
        for index in 0..<16 {
            let hex = String(format: "#%02x%02x%02x", index, index, index)
            XCTAssertTrue(text.contains("palette = \(index)=\(hex)\n"), "missing palette \(index)")
        }
    }

    func test_nilThemeStillEmitsBehaviorBaseline() {
        let text = GhosttyConfigWriter.configText(for: nil)
        XCTAssertTrue(text.contains("cursor-style = block\n"))
        // Without this, shell integration swaps the block for a bar at the prompt.
        XCTAssertTrue(text.contains("shell-integration-features = no-cursor\n"))
        XCTAssertTrue(text.contains("mouse-hide-while-typing = true\n"))
        XCTAssertFalse(text.contains("font-family"))
        XCTAssertFalse(text.contains("palette"))
    }

    func test_writeConfigProducesLoadableFile() throws {
        let path = try XCTUnwrap(GhosttyConfigWriter.writeConfig(for: theme))
        let written = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertEqual(written, GhosttyConfigWriter.configText(for: theme))
    }

    func test_nilBehaviorEmitsHistoricalBaseline() {
        // The earlier defaults, so an absent config is byte-identical to before.
        let text = GhosttyConfigWriter.configText(for: theme, behavior: nil)
        XCTAssertTrue(text.contains("cursor-style = block\n"))
        XCTAssertTrue(text.contains("cursor-style-blink = true\n"))
        XCTAssertTrue(text.contains("macos-option-as-alt = true\n"))
    }

    func test_customBehaviorEmitted() {
        let behavior = TerminalBehavior(
            cursorStyle: .bar, cursorBlink: false, cursorThickness: 4, optionAsAlt: false)
        let text = GhosttyConfigWriter.configText(for: theme, behavior: behavior)
        XCTAssertTrue(text.contains("cursor-style = bar\n"))
        XCTAssertTrue(text.contains("cursor-style-blink = false\n"))
        XCTAssertTrue(text.contains("macos-option-as-alt = false\n"))
        XCTAssertTrue(text.contains("adjust-cursor-thickness = 3\n"))  // 4px = base 1 + delta 3
    }

    func test_cursorThickness_ofOne_emitsNoAdjustment() {
        let text = GhosttyConfigWriter.configText(for: theme, behavior: TerminalBehavior(cursorThickness: 1))
        XCTAssertFalse(text.contains("adjust-cursor-thickness"))
    }

    func test_fontThicken_emitsGhosttyKeyWhenOn() {
        let text = GhosttyConfigWriter.configText(for: theme, behavior: TerminalBehavior(fontThicken: true))
        XCTAssertTrue(text.contains("font-thicken = true\n"))
    }

    /// Off by default, and nothing is emitted then, so ghostty's own default rules rather than
    /// being pinned. The chrome shipped `font-thicken = true` unconditionally until this key existed.
    func test_fontThicken_defaultsOff_emittingNoKey() {
        XCTAssertFalse(TerminalBehavior().fontThicken)
        XCTAssertFalse(
            GhosttyConfigWriter.configText(for: theme, behavior: TerminalBehavior())
                .contains("font-thicken"))
    }

    func test_noShader_emitsNeitherShaderKey() {
        let text = GhosttyConfigWriter.configText(for: theme, behavior: TerminalBehavior())
        XCTAssertFalse(text.contains("custom-shader"))
        XCTAssertFalse(text.contains("custom-shader-animation"))
    }

    func test_cursorShaderEmitsGhosttyKeyWithAnimation() {
        let behavior = TerminalBehavior(cursorShader: "/a/cursor_warp.glsl")
        let text = GhosttyConfigWriter.configText(for: theme, behavior: behavior)
        // The chrome's single `cursor-shader` maps to ghostty's own `custom-shader` key.
        XCTAssertTrue(text.contains("custom-shader = /a/cursor_warp.glsl\n"))
        // The animation loop is pinned on only when there's a shader to animate.
        XCTAssertTrue(text.contains("custom-shader-animation = true\n"))
    }

    /// The settle-burst's whole mechanism is this one token: `always` is what keeps ghostty's
    /// draw timer running on a blurred surface so the cursor tail can decay. Emit
    /// `true` here and the burst silently does nothing.
    func test_alwaysAnimation_emitsAlways_soABlurredSurfaceKeepsAnimating() {
        let behavior = TerminalBehavior(cursorShader: "/a/cursor_warp.glsl")
        let text = GhosttyConfigWriter.configText(
            for: theme, behavior: behavior, shaderAnimation: .always)
        XCTAssertTrue(text.contains("custom-shader-animation = always\n"))
        XCTAssertFalse(text.contains("custom-shader-animation = true\n"))
    }

    /// A per-surface config is written beside the app-global one, never over it: sharing the
    /// path would leave every other surface loading one blurred pane's config.
    func test_variantConfig_writesItsOwnFile_leavingTheAppGlobalOneIntact() throws {
        let behavior = TerminalBehavior(cursorShader: "/a/cursor_warp.glsl")
        let shared = try XCTUnwrap(GhosttyConfigWriter.writeConfig(for: theme, behavior: behavior))
        let perSurface = try XCTUnwrap(
            GhosttyConfigWriter.writeConfig(
                for: theme, behavior: behavior, shaderAnimation: .always, variant: "surface"))
        XCTAssertNotEqual(shared, perSurface)
        let sharedText = try String(contentsOfFile: shared, encoding: .utf8)
        XCTAssertTrue(sharedText.contains("custom-shader-animation = true\n"))
    }

    /// What actually stops a tracer: an unfocused surface runs no shader pass at all, so a
    /// cursor move after the blur has nothing to freeze into a smear.
    func test_strippedShader_emitsNoShaderKeys_soAnUnfocusedSurfaceCannotSmear() {
        var unshaded = TerminalBehavior(cursorShader: "/a/cursor_warp.glsl")
        unshaded.cursorShader = nil
        let text = GhosttyConfigWriter.configText(for: theme, behavior: unshaded)
        XCTAssertFalse(text.contains("custom-shader"))
    }

    /// The chrome's `background-alpha` maps to ghostty's own `background-opacity`.
    func test_backgroundAlphaEmitsGhosttyOpacityKey() {
        let behavior = TerminalBehavior(backgroundAlpha: 0.7)
        let text = GhosttyConfigWriter.configText(for: theme, behavior: behavior)
        XCTAssertTrue(text.contains("background-opacity = 0.7\n"))
    }

    /// Nothing is emitted at full opacity, so an unset key leaves the generated config exactly
    /// what it has always been — and ghostty keeps its own default rather than being pinned.
    func test_solidBackground_emitsNoOpacityKey() {
        let text = GhosttyConfigWriter.configText(for: theme, behavior: TerminalBehavior())
        XCTAssertFalse(text.contains("background-opacity"))
    }

    /// `BackendShadowSweepTests` covers this end to end, but it skips when `ghostty_surface_new`
    /// fails, which a locked screen does. On that run nothing else would notice the one line that
    /// writes all of these going missing.
    func test_configTextEmitsAnUnbindLineForEveryTakenBackChord() {
        let text = GhosttyConfigWriter.configText(for: nil)

        for trigger in GhosttyUnboundChords.triggers {
            XCTAssertTrue(
                text.contains("keybind = \(trigger)=unbind\n"), "no unbind line for \(trigger)")
        }
        for trigger in GhosttyUnboundChords.kept {
            XCTAssertFalse(
                text.contains("keybind = \(trigger)=unbind"), "\(trigger) is kept, not unbound")
        }
    }

    func test_defaultBehavior() {
        let behavior = TerminalBehavior()
        XCTAssertEqual(behavior.cursorStyle, .block)
        XCTAssertTrue(behavior.cursorBlink)
        XCTAssertEqual(behavior.cursorThickness, 2)
        XCTAssertTrue(behavior.optionAsAlt)
        XCTAssertEqual(behavior.scrollMultiplier, 1.5)
        XCTAssertEqual(behavior.backgroundAlpha, 1)
        XCTAssertTrue(behavior.isBackgroundSolid)
        XCTAssertNil(behavior.ghosttyBackgroundOpacity)
        XCTAssertEqual(behavior.ghosttyCursorStyle, "block")
        XCTAssertEqual(behavior.ghosttyCursorThicknessDelta, 1)  // 2px = base 1 + delta 1
        XCTAssertEqual(TerminalBehavior(cursorStyle: .bar).ghosttyCursorStyle, "bar")
        XCTAssertEqual(TerminalBehavior(cursorStyle: .underline).ghosttyCursorStyle, "underline")
    }
}
