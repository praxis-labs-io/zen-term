import XCTest

@testable import ZenTerm

final class GeneralConfigParserTests: XCTestCase {
    private func parse(_ text: String) -> GeneralConfig {
        GeneralConfigParser.parse(text, fallback: .builtIn)
    }

    func test_happyPath_parsesEveryScalar() {
        let config = parse(
            """
            font-family = Menlo
            font-size = 16
            cursor-style = bar
            cursor-style-blink = false
            macos-option-as-alt = false
            scroll-multiplier = 4
            backdrop-alpha = 0.5
            window-gutter = 16
            pane-gap = 12
            bottom-drawer-fraction = 0.4
            right-drawer-fraction = 0.45
            drawer-resize-step = 60
            max-drawer-fraction = 0.8
            reduce-motion = on
            shell = /bin/bash
            shell-args = -l -i
            """)
        XCTAssertEqual(config.fontName, "Menlo")
        XCTAssertEqual(config.fontSize, 16)
        XCTAssertEqual(config.cursorStyle, .bar)
        XCTAssertFalse(config.cursorBlink)
        XCTAssertFalse(config.optionAsAlt)
        XCTAssertEqual(config.scrollMultiplier, 4)
        XCTAssertEqual(config.backdropAlpha, 0.5)
        XCTAssertEqual(config.windowGutter, 16)
        XCTAssertEqual(config.panelGap, 12)
        XCTAssertEqual(config.bottomDrawerFraction, 0.4)
        XCTAssertEqual(config.rightDrawerFraction, 0.45)
        XCTAssertEqual(config.drawerResizeStep, 60)
        XCTAssertEqual(config.maxDrawerFraction, 0.8)
        XCTAssertEqual(config.reduceMotion, .on)
        XCTAssertEqual(config.shell, "/bin/bash")
        XCTAssertEqual(config.shellArgs, ["-l", "-i"])
    }

    func test_themeKey_setsThemeName() {
        XCTAssertEqual(parse("theme = catppuccin-mocha\n").themeName, "catppuccin-mocha")
        XCTAssertNil(parse("font-size = 14\n").themeName)  // absent → nil (legacy/default path)
    }

    func test_partial_fallsBackForUnsetKeys() {
        let config = parse("font-size = 20\n")
        XCTAssertEqual(config.fontSize, 20)
        XCTAssertEqual(config.cursorStyle, GeneralConfig.builtIn.cursorStyle)  // untouched
        XCTAssertEqual(config.backdropAlpha, GeneralConfig.builtIn.backdropAlpha)
    }

    func test_malformedValues_fallBack() {
        let config = parse(
            """
            font-size = abc
            cursor-style = wiggle
            macos-option-as-alt = maybe
            backdrop-alpha = 0.3
            """)
        XCTAssertEqual(config.fontSize, GeneralConfig.builtIn.fontSize)  // "abc" → fallback
        XCTAssertEqual(config.cursorStyle, GeneralConfig.builtIn.cursorStyle)  // "wiggle" → fallback
        XCTAssertEqual(config.optionAsAlt, GeneralConfig.builtIn.optionAsAlt)  // "maybe" → fallback
        XCTAssertEqual(config.backdropAlpha, 0.3)  // the valid line still applies
    }

    func test_outOfRange_clamps() {
        let config = parse("backdrop-alpha = 2.5\nfont-size = 2\nmax-drawer-fraction = 0.99\n")
        XCTAssertEqual(config.backdropAlpha, 1.0)  // clamped to [0, 1]
        XCTAssertEqual(config.fontSize, 6)  // clamped to [6, 72]
        XCTAssertEqual(config.maxDrawerFraction, 0.95)  // clamped to [0.3, 0.95]
    }

    func test_nonFiniteValues_fallBackWithoutCrashing() {
        // `Double("nan")`/`"inf"` parse but must not reach Int(NaN)/clamp — regression guard.
        let config = parse("cursor-thickness = nan\nscroll-multiplier = inf\nfont-size = 20\n")
        XCTAssertEqual(config.cursorThickness, GeneralConfig.builtIn.cursorThickness)
        XCTAssertEqual(config.scrollMultiplier, GeneralConfig.builtIn.scrollMultiplier)
        XCTAssertEqual(config.fontSize, 20)  // the finite line still applies
    }

    func test_cursorThickness_parsesAndClamps() {
        XCTAssertEqual(parse("cursor-thickness = 4\n").cursorThickness, 4)
        XCTAssertEqual(parse("cursor-thickness = 99\n").cursorThickness, 12)  // clamped to [1, 12]
        XCTAssertEqual(parse("cursor-thickness = 0\n").cursorThickness, 1)
    }

    func test_trailingInlineComments_stripped() {
        // Uncommenting a documented reference line leaves a trailing `# …` comment; it must
        // not corrupt the value.
        let config = parse(
            """
            cursor-style = bar                # block | bar | underline
            font-size = 16                    # points; clamped to 6…72
            """)
        XCTAssertEqual(config.cursorStyle, .bar)
        XCTAssertEqual(config.fontSize, 16)
    }

    func test_hashInsideQuotedCommand_survives() {
        let config = parse("float = id:x command:\"echo # hi\" key:cmd+shift+x\n")
        XCTAssertEqual(config.floats.first?.command, "echo # hi")
    }

    func test_unknownKeysAndComments_ignored() {
        let config = parse("# a comment\nbackground = #000000\n\nfont-size = 18\n")
        XCTAssertEqual(config.fontSize, 18)
        XCTAssertEqual(config.fontName, GeneralConfig.builtIn.fontName)  // no theme keys leak in
    }

    func test_floatsAndKeybinds_populateStructuredFields() {
        let config = parse(
            """
            float = id:gitdash command:gd key:cmd+shift+g
            keybind = toggle_command_palette=cmd+f
            """)
        XCTAssertEqual(config.floats.map(\.id), ["gitdash"])
        XCTAssertEqual(config.keymap[Chord(command: true, key: "f")], .toggleCommandPalette)
        // The float's key becomes a dynamic chord in the keymap.
        XCTAssertEqual(config.keymap[Chord(command: true, shift: true, key: "g")], .toggleToolFloat("gitdash"))
    }

    func test_duplicateFloatID_lastWins() {
        let config = parse(
            """
            float = id:x command:one key:cmd+shift+a
            float = id:x command:two key:cmd+shift+b
            """)
        XCTAssertEqual(config.floats.count, 1)
        XCTAssertEqual(config.floats.first?.command, "two")
    }
}
