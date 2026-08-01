import XCTest

@testable import ZenTerm

final class GeneralConfigParserTests: XCTestCase {
    private func parse(_ text: String) -> GeneralConfig {
        GeneralConfigParser.parse(text, fallback: .builtIn)
    }

    func test_cursorShader_isSingleSelect_lastNonEmptyWins() {
        // Single-select: the parser stores the raw bundled-shader name (ConfigLoader resolves it),
        // last non-empty line wins, and an empty value is skipped.
        let config = parse(
            """
            cursor-shader = cursor_warp
            cursor-shader =
            cursor-shader = cursor_tail
            """)
        XCTAssertEqual(config.cursorShader, "cursor_tail")
    }

    func test_noCursorShader_isNil() {
        XCTAssertNil(parse("font-family = Menlo").cursorShader)
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
            background-alpha = 0.7
            window-chrome = false
            backdrop-alpha = 0.5
            window-gutter = 16
            pane-gap = 12
            bottom-drawer-fraction = 0.4
            right-drawer-fraction = 0.45
            drawer-resize-step = 60
            max-drawer-fraction = 0.8
            reduce-motion = on
            diff-layout = inline
            shell = /bin/bash
            shell-args = -l -i
            editor = vim
            ai = codex
            """)
        XCTAssertEqual(config.fontName, "Menlo")
        XCTAssertEqual(config.fontSize, 16)
        XCTAssertEqual(config.cursorStyle, .bar)
        XCTAssertFalse(config.cursorBlink)
        XCTAssertFalse(config.optionAsAlt)
        XCTAssertEqual(config.scrollMultiplier, 4)
        XCTAssertEqual(config.backgroundAlpha, 0.7)
        XCTAssertFalse(config.windowChrome)
        XCTAssertEqual(config.backdropAlpha, 0.5)
        XCTAssertEqual(config.windowGutter, 16)
        XCTAssertEqual(config.panelGap, 12)
        XCTAssertEqual(config.bottomDrawerFraction, 0.4)
        XCTAssertEqual(config.rightDrawerFraction, 0.45)
        XCTAssertEqual(config.drawerResizeStep, 60)
        XCTAssertEqual(config.maxDrawerFraction, 0.8)
        XCTAssertEqual(config.reduceMotion, .on)
        XCTAssertEqual(config.diffLayout, .inline)
        XCTAssertEqual(config.shell, "/bin/bash")
        XCTAssertEqual(config.shellArgs, ["-l", "-i"])
        XCTAssertEqual(config.editor, "vim")
        XCTAssertEqual(config.ai, "codex")
    }

    func test_editorAndAI_absent_fallsBackToNil() {
        let config = parse("font-size = 14\n")
        XCTAssertNil(config.editor)  // absent → nil → the preset's nvim/claude fallback
        XCTAssertNil(config.ai)
    }

    func test_automaticUpdateChecks_parsesAndDefaultsOn() {
        XCTAssertFalse(parse("automatic-update-checks = false\n").automaticUpdateChecks)
        XCTAssertTrue(parse("automatic-update-checks = true\n").automaticUpdateChecks)
        XCTAssertTrue(parse("automatic-update-checks = maybe\n").automaticUpdateChecks)  // malformed → default
        XCTAssertTrue(parse("font-size = 14\n").automaticUpdateChecks)  // absent → default (on)
    }

    func test_debug_parsesAndDefaultsOff() {
        XCTAssertTrue(parse("debug = true\n").debug)
        XCTAssertFalse(parse("debug = false\n").debug)
        XCTAssertFalse(parse("debug = maybe\n").debug)  // malformed → default (off)
        XCTAssertFalse(parse("font-size = 14\n").debug)  // absent → default (off)
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
        XCTAssertEqual(config.backgroundAlpha, GeneralConfig.builtIn.backgroundAlpha)  // 1 = solid
    }

    func test_malformedValues_fallBack() {
        let config = parse(
            """
            font-size = abc
            cursor-style = wiggle
            macos-option-as-alt = maybe
            window-chrome = sometimes
            backdrop-alpha = 0.3
            """)
        XCTAssertEqual(config.fontSize, GeneralConfig.builtIn.fontSize)  // "abc" → fallback
        XCTAssertEqual(config.cursorStyle, GeneralConfig.builtIn.cursorStyle)  // "wiggle" → fallback
        XCTAssertEqual(config.optionAsAlt, GeneralConfig.builtIn.optionAsAlt)  // "maybe" → fallback
        XCTAssertEqual(config.windowChrome, GeneralConfig.builtIn.windowChrome)  // "sometimes" → fallback (true)
        XCTAssertEqual(config.backdropAlpha, 0.3)  // the valid line still applies
    }

    func test_outOfRange_clamps() {
        let config = parse(
            "backdrop-alpha = 2.5\nbackground-alpha = -0.5\nfont-size = 2\nmax-drawer-fraction = 0.99\n")
        XCTAssertEqual(config.backdropAlpha, 1.0)  // clamped to [0, 1]
        XCTAssertEqual(config.backgroundAlpha, 0)  // clamped to [0, 1]
        XCTAssertEqual(config.fontSize, 6)  // clamped to [6, 32]
        XCTAssertEqual(config.maxDrawerFraction, 0.95)  // clamped to [0.3, 0.95]
    }

    /// The ceiling came down to 32 with ZEN-224, so that ⌘+ / ⌘- and the config file bound the size
    /// the same way. A config asking for more lands on 32 rather than the old 72.
    func test_fontSize_clampsToTheSteppingCeiling() {
        XCTAssertEqual(parse("font-size = 40\n").fontSize, 32)
        XCTAssertEqual(parse("font-size = 32\n").fontSize, 32)  // the ceiling itself is legal
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
        let config = parse("float = title:x command:\"echo # hi\" key:cmd+shift+x\n")
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
            float = title:gitdash command:gd key:cmd+shift+g
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
            float = title:x command:one key:cmd+shift+a
            float = title:x command:two key:cmd+shift+b
            """)
        XCTAssertEqual(config.floats.count, 1)
        XCTAssertEqual(config.floats.first?.command, "two")
    }

    // MARK: float order (ZEN-145)

    /// `config.floats` is the single array the dock, ⌘P, and Settings → Tools all read, so this sort
    /// is what "reorder" actually means end to end.
    func test_floats_sortByOrderField() {
        let config = parse(
            """
            float = order:3 title:c command:c key:cmd+shift+c
            float = order:1 title:a command:a key:cmd+shift+a
            float = order:2 title:b command:b key:cmd+shift+b
            """)
        XCTAssertEqual(config.floats.map(\.id), ["a", "b", "c"])
    }

    /// A config written before `order:` existed must be untouched by it: no `order:` anywhere means
    /// the floats keep the order their lines appear in.
    func test_floats_withoutOrder_keepFileOrder() {
        let config = parse(
            """
            float = title:c command:c key:cmd+shift+c
            float = title:a command:a key:cmd+shift+a
            float = title:b command:b key:cmd+shift+b
            """)
        XCTAssertEqual(config.floats.map(\.id), ["c", "a", "b"])
    }

    /// Swift's sort isn't stable, so a shared `order:` has to be broken by line order explicitly —
    /// otherwise the dock could silently shuffle between launches of an unchanged config.
    func test_floats_tiedOrder_brokenByFileOrder_deterministically() {
        let text = """
            float = order:1 title:a command:a key:cmd+shift+a
            float = order:1 title:b command:b key:cmd+shift+b
            float = order:1 title:c command:c key:cmd+shift+c
            """
        for _ in 0..<50 {
            XCTAssertEqual(parse(text).floats.map(\.id), ["a", "b", "c"])
        }
    }

    /// A half-numbered config — what you get by hand-editing one line of a config Settings hasn't
    /// reordered yet. An unnumbered float's order *is* its line position, so numbers and positions
    /// sort on one scale: here `a` is pushed behind the two unnumbered floats holding positions 1 and
    /// 2, rather than numbered floats forming a separate group that jumps the queue.
    func test_floats_mixedOrderAndUnordered_sortOnOneScale() {
        let config = parse(
            """
            float = order:5 title:a command:a key:cmd+shift+a
            float = title:b command:b key:cmd+shift+b
            float = title:c command:c key:cmd+shift+c
            """)
        XCTAssertEqual(config.floats.map(\.id), ["b", "c", "a"])
    }

    // MARK: hide-toolbar-buttons (ZEN-327)

    func test_hideToolbarButtons_absent_hidesNothing() {
        XCTAssertEqual(parse("font-size = 14\n").hiddenToolbarButtons, [])
    }

    func test_hideToolbarButtons_parsesEverySlug() {
        let config = parse(
            "hide-toolbar-buttons = new-tab,split-h,split-v,bottom-drawer,right-drawer,"
                + "focus-mode,command-palette,diff-viewer\n")
        XCTAssertEqual(config.hiddenToolbarButtons, Set(ToolbarButton.allCases))
    }

    func test_hideToolbarButtons_toleratesWhitespaceAndStrayCommas() {
        let config = parse("hide-toolbar-buttons = split-h , ,diff-viewer,\n")
        XCTAssertEqual(config.hiddenToolbarButtons, [.splitHorizontal, .diffViewer])
        XCTAssertTrue(config.configDiagnostics.isEmpty)
    }

    /// `.ignoredListItem`, not `.invalidValue`: the latter's rendered message claims "Using the
    /// default." while the known slugs on the line still apply — the message would contradict the
    /// visibly hidden button.
    func test_hideToolbarButtons_unknownSlug_diagnosesAndKeepsKnownOnes() {
        let config = parse("hide-toolbar-buttons = split-h,zoom,diff-viewer\n")
        XCTAssertEqual(config.hiddenToolbarButtons, [.splitHorizontal, .diffViewer])
        XCTAssertEqual(
            config.configDiagnostics,
            [
                ConfigDiagnostic(
                    scope: .setting(key: "hide-toolbar-buttons"),
                    problem: .ignoredListItem(
                        got: "zoom",
                        expected: ToolbarButton.allCases.map(\.rawValue).joined(separator: ", ")))
            ])
    }

    // MARK: config diagnostics (ZEN-7)
    //
    // The scalar/enum/float fallbacks used to log-and-drop with no trace a surface could show. Each
    // now collects a `ConfigDiagnostic` too — the piece that can go silently dead, so it's asserted.

    func test_invalidScalars_collectInvalidValueDiagnostics() {
        let diagnostics = parse(
            """
            cursor-style = beam
            macos-option-as-alt = yep
            reduce-motion = maybe
            diff-layout = sideways
            """
        ).configDiagnostics
        XCTAssertEqual(
            diagnostics,
            [
                ConfigDiagnostic(
                    scope: .setting(key: "cursor-style"),
                    problem: .invalidValue(got: "beam", expected: "block, bar, or underline")),
                ConfigDiagnostic(
                    scope: .setting(key: "macos-option-as-alt"),
                    problem: .invalidValue(got: "yep", expected: "true or false")),
                ConfigDiagnostic(
                    scope: .setting(key: "reduce-motion"),
                    problem: .invalidValue(got: "maybe", expected: "system, on, or off")),
                ConfigDiagnostic(
                    scope: .setting(key: "diff-layout"),
                    problem: .invalidValue(got: "sideways", expected: "side-by-side or inline")),
            ])
    }

    func test_outOfRangeNumber_collectsAClampedDiagnostic() {
        XCTAssertEqual(
            parse("font-size = 200\n").configDiagnostics,
            [ConfigDiagnostic(scope: .setting(key: "font-size"), problem: .clamped(value: "200", to: "32"))])
    }

    func test_nonFiniteNumber_collectsInvalidValueNotClamp() {
        // "inf" is rejected in parseDouble before clamp ever runs, so it reads as invalid, not clamped.
        XCTAssertEqual(
            parse("scroll-multiplier = inf\n").configDiagnostics,
            [
                ConfigDiagnostic(
                    scope: .setting(key: "scroll-multiplier"),
                    problem: .invalidValue(got: "inf", expected: "a number"))
            ])
    }

    func test_validConfig_collectsNoDiagnostics() {
        XCTAssertTrue(
            parse("font-size = 16\ncursor-style = bar\nreduce-motion = on\ndiff-layout = inline\n")
                .configDiagnostics.isEmpty)
    }

    func test_unparseableKeybindLine_collectsADiagnostic() {
        XCTAssertEqual(
            parse("keybind = totally bogus\n").configDiagnostics,
            [ConfigDiagnostic(scope: .keybindLine, problem: .unparseableLine("totally bogus"))])
    }

    func test_droppedFloatLine_collectsADiagnostic() {
        XCTAssertEqual(
            parse("float = title:Notes key:cmd+shift+n\n").configDiagnostics,  // no command:
            [ConfigDiagnostic(scope: .toolFloat(label: "Notes"), problem: .floatMissingField("command:"))])
    }

    func test_keybindConflict_stillCollected_alongsideScalarDiagnostics() {
        // The keybind diagnostics come from KeymapAssembler; the scalar ones from the parse loop.
        // Both must land in the one `configDiagnostics` array.
        let diagnostics = parse(
            """
            font-size = 200
            keybind = toggle_focus_mode=cmd+shift+\\
            """
        ).configDiagnostics
        XCTAssertTrue(
            diagnostics.contains(
                ConfigDiagnostic(scope: .setting(key: "font-size"), problem: .clamped(value: "200", to: "32"))))
        XCTAssertTrue(diagnostics.contains { if case .keybind = $0.scope { return true } else { return false } })
    }
}
