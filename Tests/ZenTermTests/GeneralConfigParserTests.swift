import XCTest

@testable import ZenTerm

final class GeneralConfigParserTests: XCTestCase {
    private func parse(_ text: String) -> GeneralConfig {
        GeneralConfigParser.parse(text, fallback: .builtIn)
    }

    func test_cursorShader_isSingleSelect_lastNonEmptyWins() {
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
            font-thicken = true
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
            shell = /bin/bash
            shell-args = -l -i
            tab-inherit-cwd = true
            editor = vim
            ai = codex
            """)
        XCTAssertEqual(config.fontName, "Menlo")
        XCTAssertEqual(config.fontSize, 16)
        XCTAssertEqual(config.cursorStyle, .bar)
        XCTAssertFalse(config.cursorBlink)
        XCTAssertFalse(config.optionAsAlt)
        XCTAssertTrue(config.fontThicken)
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
        XCTAssertEqual(config.shell, "/bin/bash")
        XCTAssertEqual(config.shellArgs, ["-l", "-i"])
        XCTAssertTrue(config.tabInheritCWD)
        XCTAssertEqual(config.editor, "vim")
        XCTAssertEqual(config.ai, "codex")
    }

    func test_editorAndAI_absent_fallsBackToNil() {
        let config = parse("font-size = 14\n")
        XCTAssertNil(config.editor)
        XCTAssertNil(config.ai)
    }

    func test_automaticUpdateChecks_parsesAndDefaultsOn() {
        XCTAssertFalse(parse("automatic-update-checks = false\n").automaticUpdateChecks)
        XCTAssertTrue(parse("automatic-update-checks = true\n").automaticUpdateChecks)
        XCTAssertTrue(parse("automatic-update-checks = maybe\n").automaticUpdateChecks)
        XCTAssertTrue(parse("font-size = 14\n").automaticUpdateChecks)
    }

    func test_fontThicken_parsesAndDefaultsOff() {
        XCTAssertTrue(parse("font-thicken = true\n").fontThicken)
        XCTAssertFalse(parse("font-thicken = false\n").fontThicken)
        XCTAssertFalse(parse("font-thicken = maybe\n").fontThicken)
        XCTAssertFalse(parse("font-size = 14\n").fontThicken)
    }

    func test_tabInheritCWD_parsesAndDefaultsOff() {
        XCTAssertTrue(parse("tab-inherit-cwd = true\n").tabInheritCWD)
        XCTAssertFalse(parse("tab-inherit-cwd = false\n").tabInheritCWD)
        XCTAssertFalse(parse("tab-inherit-cwd = maybe\n").tabInheritCWD)
        XCTAssertFalse(parse("font-size = 14\n").tabInheritCWD)
    }

    func test_debug_parsesAndDefaultsOff() {
        XCTAssertTrue(parse("debug = true\n").debug)
        XCTAssertFalse(parse("debug = false\n").debug)
        XCTAssertFalse(parse("debug = maybe\n").debug)
        XCTAssertFalse(parse("font-size = 14\n").debug)
    }

    func test_themeKey_setsThemeName() {
        XCTAssertEqual(parse("theme = catppuccin-mocha\n").themeName, "catppuccin-mocha")
        XCTAssertNil(parse("font-size = 14\n").themeName)
    }

    func test_partial_fallsBackForUnsetKeys() {
        let config = parse("font-size = 20\n")
        XCTAssertEqual(config.fontSize, 20)
        XCTAssertEqual(config.cursorStyle, GeneralConfig.builtIn.cursorStyle)
        XCTAssertEqual(config.backdropAlpha, GeneralConfig.builtIn.backdropAlpha)
        XCTAssertEqual(config.backgroundAlpha, GeneralConfig.builtIn.backgroundAlpha)
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
        XCTAssertEqual(config.fontSize, GeneralConfig.builtIn.fontSize)
        XCTAssertEqual(config.cursorStyle, GeneralConfig.builtIn.cursorStyle)
        XCTAssertEqual(config.optionAsAlt, GeneralConfig.builtIn.optionAsAlt)
        XCTAssertEqual(config.windowChrome, GeneralConfig.builtIn.windowChrome)
        XCTAssertEqual(config.backdropAlpha, 0.3)
    }

    func test_outOfRange_clamps() {
        let config = parse(
            "backdrop-alpha = 2.5\nbackground-alpha = -0.5\nfont-size = 2\nmax-drawer-fraction = 0.99\n")
        XCTAssertEqual(config.backdropAlpha, 1.0)
        XCTAssertEqual(config.backgroundAlpha, 0)
        XCTAssertEqual(config.fontSize, 6)
        XCTAssertEqual(config.maxDrawerFraction, 0.95)
    }

    func test_fontSize_clampsToTheSteppingCeiling() {
        XCTAssertEqual(parse("font-size = 40\n").fontSize, 32)
        XCTAssertEqual(parse("font-size = 32\n").fontSize, 32)
    }

    func test_nonFiniteValues_fallBackWithoutCrashing() {
        let config = parse("cursor-thickness = nan\nscroll-multiplier = inf\nfont-size = 20\n")
        XCTAssertEqual(config.cursorThickness, GeneralConfig.builtIn.cursorThickness)
        XCTAssertEqual(config.scrollMultiplier, GeneralConfig.builtIn.scrollMultiplier)
        XCTAssertEqual(config.fontSize, 20)
    }

    func test_cursorThickness_parsesAndClamps() {
        XCTAssertEqual(parse("cursor-thickness = 4\n").cursorThickness, 4)
        XCTAssertEqual(parse("cursor-thickness = 99\n").cursorThickness, 12)
        XCTAssertEqual(parse("cursor-thickness = 0\n").cursorThickness, 1)
    }

    func test_trailingInlineComments_stripped() {
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
        XCTAssertEqual(config.fontName, GeneralConfig.builtIn.fontName)
    }

    func test_floatsAndKeybinds_populateStructuredFields() {
        let config = parse(
            """
            float = title:gitdash command:gd key:cmd+shift+g
            keybind = toggle_command_palette=cmd+f
            """)
        XCTAssertEqual(config.floats.map(\.id), ["gitdash"])
        XCTAssertEqual(config.keymap[Chord(command: true, key: "f")], .toggleCommandPalette)
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

    func test_floats_sortByOrderField() {
        let config = parse(
            """
            float = order:3 title:c command:c key:cmd+shift+c
            float = order:1 title:a command:a key:cmd+shift+a
            float = order:2 title:b command:b key:cmd+shift+b
            """)
        XCTAssertEqual(config.floats.map(\.id), ["a", "b", "c"])
    }

    func test_floats_withoutOrder_keepFileOrder() {
        let config = parse(
            """
            float = title:c command:c key:cmd+shift+c
            float = title:a command:a key:cmd+shift+a
            float = title:b command:b key:cmd+shift+b
            """)
        XCTAssertEqual(config.floats.map(\.id), ["c", "a", "b"])
    }

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

    func test_floats_mixedOrderAndUnordered_sortOnOneScale() {
        let config = parse(
            """
            float = order:5 title:a command:a key:cmd+shift+a
            float = title:b command:b key:cmd+shift+b
            float = title:c command:c key:cmd+shift+c
            """)
        XCTAssertEqual(config.floats.map(\.id), ["b", "c", "a"])
    }

    func test_hideToolbarButtons_absent_hidesNothing() {
        XCTAssertEqual(parse("font-size = 14\n").hiddenToolbarButtons, [])
    }

    func test_hideToolbarButtons_parsesEverySlug() {
        let config = parse(
            "hide-toolbar-buttons = new-tab,split-h,split-v,bottom-drawer,right-drawer,scratch,"
                + "focus-mode,command-palette,settings\n")
        XCTAssertEqual(config.hiddenToolbarButtons, Set(ToolbarButton.allCases))
    }

    func test_hideToolbarButtons_toleratesWhitespaceAndStrayCommas() {
        let config = parse("hide-toolbar-buttons = split-h , ,focus-mode,\n")
        XCTAssertEqual(config.hiddenToolbarButtons, [.splitHorizontal, .focusMode])
        XCTAssertTrue(config.configDiagnostics.isEmpty)
    }

    func test_hideToolbarButtons_unknownSlug_diagnosesAndKeepsKnownOnes() {
        let config = parse("hide-toolbar-buttons = split-h,zoom,focus-mode\n")
        XCTAssertEqual(config.hiddenToolbarButtons, [.splitHorizontal, .focusMode])
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

    func test_invalidScalars_collectInvalidValueDiagnostics() {
        let diagnostics = parse(
            """
            cursor-style = beam
            macos-option-as-alt = yep
            reduce-motion = maybe
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
            ])
    }

    func test_toastKeys_parse() {
        let config = parse(
            """
            attention-toast = auto
            completion-toast = auto
            toast-duration = 8
            """)
        XCTAssertEqual(config.attentionToast, .auto)
        XCTAssertEqual(config.completionToast, .auto)
        XCTAssertEqual(config.toastDuration, 8)
    }

    func test_toastKeys_defaultToSticky() {
        let config = parse("")
        XCTAssertEqual(config.attentionToast, .sticky)
        XCTAssertEqual(config.completionToast, .sticky)
        XCTAssertEqual(config.toastDuration, 4)
    }

    func test_invalidToastDismissal_namesTheKeyThatWasWrong() {
        let diagnostics = parse(
            """
            attention-toast = forever
            completion-toast = whenever
            """
        ).configDiagnostics
        XCTAssertEqual(
            diagnostics,
            [
                ConfigDiagnostic(
                    scope: .setting(key: "attention-toast"),
                    problem: .invalidValue(got: "forever", expected: "sticky or auto")),
                ConfigDiagnostic(
                    scope: .setting(key: "completion-toast"),
                    problem: .invalidValue(got: "whenever", expected: "sticky or auto")),
            ])
    }

    func test_toastDuration_clampsToItsRange() {
        XCTAssertEqual(parse("toast-duration = 99\n").toastDuration, 60)
        XCTAssertEqual(parse("toast-duration = 0\n").toastDuration, 1)
        XCTAssertEqual(
            parse("toast-duration = 99\n").configDiagnostics,
            [
                ConfigDiagnostic(
                    scope: .setting(key: "toast-duration"), problem: .clamped(value: "99", to: "60"))
            ])
    }

    func test_outOfRangeNumber_collectsAClampedDiagnostic() {
        XCTAssertEqual(
            parse("font-size = 200\n").configDiagnostics,
            [ConfigDiagnostic(scope: .setting(key: "font-size"), problem: .clamped(value: "200", to: "32"))])
    }

    func test_nonFiniteNumber_collectsInvalidValueNotClamp() {
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
            parse("font-size = 16\ncursor-style = bar\nreduce-motion = on\n")
                .configDiagnostics.isEmpty)
    }

    func test_unparseableKeybindLine_collectsADiagnostic() {
        XCTAssertEqual(
            parse("keybind = totally bogus\n").configDiagnostics,
            [ConfigDiagnostic(scope: .keybindLine, problem: .unparseableLine("totally bogus"))])
    }

    func test_retiredKeybindAction_takesNoDiagnostic() {
        XCTAssertEqual(parse("keybind = diff_viewer=cmd+g\n").configDiagnostics, [])
        XCTAssertEqual(parse("keybind = diff_viewer=cmd+shift+g\n").configDiagnostics, [])
    }

    func test_aTypoOnTheRetiredAction_stillReportsUnparseable() {
        XCTAssertEqual(
            parse("keybind = diff_viewer_old=cmd+g\n").configDiagnostics,
            [ConfigDiagnostic(scope: .keybindLine, problem: .unparseableLine("diff_viewer_old=cmd+g"))])
    }

    func test_retiredToolbarSlug_isDroppedWithoutADiagnostic() {
        let config = parse("hide-toolbar-buttons = split-h,diff-viewer\n")
        XCTAssertEqual(config.hiddenToolbarButtons, [.splitHorizontal])
        XCTAssertEqual(config.configDiagnostics, [])
    }

    func test_sidebarFooterSlugs_parseAsButtons() {
        let config = parse("hide-toolbar-buttons = split-h,command-palette,settings\n")
        XCTAssertEqual(config.hiddenToolbarButtons, [.splitHorizontal, .commandPalette, .settings])
        XCTAssertEqual(config.configDiagnostics, [])
    }

    func test_droppedFloatLine_collectsADiagnostic() {
        XCTAssertEqual(
            parse("float = title:Notes key:cmd+shift+n\n").configDiagnostics,
            [ConfigDiagnostic(scope: .toolFloat(label: "Notes"), problem: .floatMissingField("command:"))])
    }

    func test_keybindConflict_stillCollected_alongsideScalarDiagnostics() {
        let diagnostics = parse(
            """
            font-size = 200
            keybind = toggle_focus_mode=cmd+d
            """
        ).configDiagnostics
        XCTAssertTrue(
            diagnostics.contains(
                ConfigDiagnostic(scope: .setting(key: "font-size"), problem: .clamped(value: "200", to: "32"))))
        XCTAssertTrue(diagnostics.contains { if case .keybind = $0.scope { return true } else { return false } })
    }
}
