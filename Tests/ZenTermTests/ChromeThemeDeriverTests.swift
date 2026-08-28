import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

final class ChromeThemeDeriverTests: XCTestCase {
    func test_derivesRolesFromPaletteMatchingLegacyToastColors() {
        let chrome = ChromeThemeDeriver.derive(from: Theme.rosePineZen)
        XCTAssertEqual(chrome.background, TerminalColor(hex: "#191724"))
        XCTAssertEqual(chrome.foreground, TerminalColor(hex: "#e0def4"))
        XCTAssertEqual(chrome.info, TerminalColor(hex: "#9ccfd8"))  // foam / palette[4]
        XCTAssertEqual(chrome.warning, TerminalColor(hex: "#f6c177"))  // gold / palette[3]
        XCTAssertEqual(chrome.destructive, TerminalColor(hex: "#eb6f92"))  // love / palette[1]
        // Shares palette[4] with `info` by default; `accent-color` repoints it per user.
        XCTAssertEqual(chrome.accent, TerminalColor(hex: "#9ccfd8"))  // foam / palette[4]
        XCTAssertEqual(chrome.attention, TerminalColor(hex: "#ea9a97"))  // rose / palette[6]
        XCTAssertEqual(chrome.positive, TerminalColor(hex: "#3e8fb0"))  // pine / palette[2] (ANSI green)
        // muted = foreground (#e0def4 = 224,222,244) blended over background (#191724 =
        // 25,23,36) at 0.55: round(fg*0.55 + bg*0.45) per channel.
        //   R: 224*0.55 + 25*0.45 = 123.2 + 11.25 = 134.45 -> 134
        //   G: 222*0.55 + 23*0.45 = 122.1 + 10.35 = 132.45 -> 132
        //   B: 244*0.55 + 36*0.45 = 134.2 + 16.2  = 150.4  -> 150
        XCTAssertEqual(chrome.muted, TerminalColor(red: 134, green: 132, blue: 150))
    }

    func test_chromeThemeStaysEquatable_acrossAllFields() {
        // A round-trip equality that touches every stored field, guarding the synthesized
        // `Equatable` conformance.
        XCTAssertEqual(
            ChromeThemeDeriver.derive(from: Theme.rosePineZen),
            ChromeThemeDeriver.derive(from: Theme.rosePineZen))
        var recolored = Theme.rosePineZen
        // The default accent's slot, read from the constant: pinning an index here made this assert
        // nothing the moment the default moved off it.
        recolored.ansi[AccentSlot.themeDefault.ansiIndex] = TerminalColor(red: 255, green: 255, blue: 255)
        XCTAssertNotEqual(
            ChromeThemeDeriver.derive(from: Theme.rosePineZen),
            ChromeThemeDeriver.derive(from: recolored))
    }

    /// `accent-color` repoints the accent role and nothing else. The "nothing else" half is the one
    /// that can rot silently, and it is no longer hypothetical: the default accent shares palette[4]
    /// with `info`, so a deriver change could drag `info` along and still look plausible.
    func test_accentOverride_movesOnlyTheAccentRole() {
        let base = ChromeThemeDeriver.derive(from: Theme.rosePineZen)
        let overridden = ChromeThemeDeriver.derive(from: Theme.rosePineZen, accent: .brightGreen)

        XCTAssertEqual(overridden.accent, TerminalColor(hex: "#3e8fb0"))  // palette[10]
        XCTAssertNotEqual(overridden.accent, base.accent)
        XCTAssertEqual(overridden.info, base.info)
        XCTAssertEqual(overridden.warning, base.warning)
        XCTAssertEqual(overridden.destructive, base.destructive)
        XCTAssertEqual(overridden.attention, base.attention)
        XCTAssertEqual(overridden.positive, base.positive)
        XCTAssertEqual(overridden.muted, base.muted)
        XCTAssertEqual(overridden.background, base.background)
        XCTAssertEqual(overridden.foreground, base.foreground)
    }

    /// An unset key resolves to `themeDefault`, and the slot it names is pinned here. Both halves
    /// matter: the first catches the nil path breaking, the second stops the default being repointed
    /// by accident, which would silently recolor the chrome for every user who never opened it.
    func test_noAccentOverride_resolvesToTheDefaultSlot() {
        XCTAssertEqual(AccentSlot.themeDefault, .blue)
        XCTAssertEqual(
            ChromeThemeDeriver.derive(from: Theme.rosePineZen, accent: nil).accent,
            ChromeThemeDeriver.derive(from: Theme.rosePineZen, accent: AccentSlot.themeDefault).accent)
    }

    /// Every slot has to name the ANSI entry the palette actually put there — an off-by-one here
    /// would hand the user a color under the wrong name, which no assertion elsewhere would catch.
    func test_everySlotResolvesToItsPaletteEntry() {
        for slot in AccentSlot.allCases {
            XCTAssertEqual(
                ChromeThemeDeriver.derive(from: Theme.rosePineZen, accent: slot).accent,
                Theme.rosePineZen.ansi[slot.ansiIndex],
                "\(slot.rawValue) resolved to the wrong palette entry")
        }
    }

    /// A hand-written theme file may declare fewer than 16 entries; a high slot must fall back, not
    /// trap. `slot(_:)` already did this for the fixed roles — the override must not bypass it.
    func test_slotBeyondAShortPalette_fallsBackToForeground() {
        var short = Theme.rosePineZen
        short.ansi = Array(short.ansi.prefix(8))
        XCTAssertEqual(
            ChromeThemeDeriver.derive(from: short, accent: .brightWhite).accent, short.foreground)
    }

    func test_inkIsThemeForegroundAtTheBoostedLevelAlpha() {
        let chrome = ChromeThemeDeriver.derive(from: Theme.rosePineZen)
        for level in ChromeTheme.InkLevel.allCases {
            assertEqualRGBA(
                chrome.ink(level),
                Theme.rosePineZen.foreground.nsColor
                    .withAlphaComponent(min(1, level.alpha * ChromeTheme.inkBoost)))
        }
    }

    /// The multiplier must not clamp a level that is not meant to be full opacity. At 1.3 four of the
    /// old hand-tuned alphas collapsed into 1 and the ceiling was invisible to anyone tuning a value;
    /// this fails the moment a raised boost pulls a level up into `normal`.
    func test_theBoost_clampsOnlyTheNormalLevel() {
        let chrome = ChromeThemeDeriver.derive(from: Theme.rosePineZen)
        for level in ChromeTheme.InkLevel.allCases where level != .normal {
            XCTAssertLessThan(
                chrome.ink(level).alphaComponent, 1, "\(level) has been boosted into normal")
        }
        XCTAssertEqual(chrome.ink(.normal).alphaComponent, 1, accuracy: 0.0001)
    }

    /// The scale has to stay ordered and distinct: two levels that collapse are one level, and a
    /// swap inverts every hierarchy built on them. Reads `allCases` so adding a level cannot skip
    /// this, which is the whole reason the enum is `CaseIterable`.
    func test_theInkLevels_areOrderedAndDistinct() {
        let alphas = ChromeTheme.InkLevel.allCases.map(\.alpha)
        XCTAssertEqual(alphas, alphas.sorted(), "declaration order is the weight order")
        XCTAssertEqual(Set(alphas).count, alphas.count, "two levels share an alpha")
        XCTAssertEqual(ChromeTheme.InkLevel.normal.alpha, 1, "normal is full strength or it is not normal")
        XCTAssertEqual(ChromeTheme.InkLevel.allCases.last, .normal, "normal is the top of the ramp")
    }

    /// `faint` is the bottom of the ramp, and it has to stay clear of the `1 / inkBoost` ceiling —
    /// a level declared above 0.87 paints as `normal` while reading in source like a quiet one.
    func test_faint_isTheQuietestLevelAndClearsTheClamp() {
        let chrome = ChromeThemeDeriver.derive(from: Theme.rosePineZen)
        XCTAssertEqual(ChromeTheme.InkLevel.allCases.first, .faint)
        XCTAssertLessThan(
            chrome.ink(.faint).alphaComponent, chrome.ink(.muted).alphaComponent,
            "faint has collapsed into muted")
        XCTAssertLessThan(
            ChromeTheme.InkLevel.faint.alpha, 1 / ChromeTheme.inkBoost,
            "faint is above the clamp and paints opaque")
    }

    func test_aThemeSilentOnSelectedTextGetsItsOwnForeground() {
        XCTAssertNil(Theme.rosePineZen.selectionForeground)  // the file names no such key
        XCTAssertEqual(
            AppTheme(terminal: Theme.rosePineZen).terminal.selectionForeground,
            Theme.rosePineZen.foreground)
    }

    func test_aThemeThatNamesSelectedTextKeepsWhatItNamed() {
        var named = Theme.rosePineZen
        named.selectionForeground = TerminalColor(hex: "#abcdef")
        XCTAssertEqual(
            AppTheme(terminal: named).terminal.selectionForeground, TerminalColor(hex: "#abcdef"))
    }

    /// Compares two `NSColor`s by their RGBA components, converting both through `.sRGB`
    /// first since the source colors aren't guaranteed to already be in that color space.
    private func assertEqualRGBA(
        _ lhs: NSColor, _ rhs: NSColor, file: StaticString = #filePath, line: UInt = #line
    ) {
        guard let lhsRGB = lhs.usingColorSpace(.sRGB), let rhsRGB = rhs.usingColorSpace(.sRGB)
        else {
            XCTFail("could not convert colors to sRGB", file: file, line: line)
            return
        }
        XCTAssertEqual(lhsRGB.redComponent, rhsRGB.redComponent, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(
            lhsRGB.greenComponent, rhsRGB.greenComponent, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(lhsRGB.blueComponent, rhsRGB.blueComponent, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(
            lhsRGB.alphaComponent, rhsRGB.alphaComponent, accuracy: 0.001, file: file, line: line)
    }

    // MARK: - fill normalisation across the catalog

    /// **This test is why nobody has to walk sixty-five themes.**
    ///
    /// A fill's declared alpha is constant, but what it *looks like* depends on how far a theme's
    /// foreground sits from its background, and across the catalog that ranges from 0.40 to 0.94. So
    /// the same 0.10 border was more than twice as faint in one theme as another. `fillScale`
    /// normalises the achieved luminance delta instead; this asserts it landed, for every bundled
    /// theme, which is a budget no glance can check even one theme at a time.
    func test_everyBundledTheme_landsAHairlineAtTheSameVisibleDelta() throws {
        func perceived(_ c: TerminalColor) -> CGFloat {
            0.299 * CGFloat(c.red) / 255 + 0.587 * CGFloat(c.green) / 255 + 0.114 * CGFloat(c.blue) / 255
        }
        var deltas: [(String, CGFloat)] = []
        for entry in ThemeCatalog.bundled {
            let url = try XCTUnwrap(ThemeCatalog.bundledURL(for: entry.token))
            let terminal = GhosttyThemeParser.parse(
                try String(contentsOf: url, encoding: .utf8), fontName: "Menlo", fontSize: 12,
                fallback: Theme.rosePineZen)
            let chrome = ChromeThemeDeriver.derive(from: terminal)
            let alpha = chrome.fill(alpha: ChromeTheme.border).alphaComponent
            let background = perceived(terminal.background)
            let painted = perceived(terminal.foreground) * alpha + background * (1 - alpha)
            deltas.append((entry.token, abs(painted - background)))
        }
        // Asserted per theme against the target, not theme against theme. A ratio bound tightens as
        // the catalog grows: well-separated themes are deliberately never scaled down, so adding a
        // high-contrast theme pushes the spread up and fails a test that has nothing to do with the
        // addition. Each theme reaching the floor is stable however many arrive.
        let target = ChromeTheme.border * ChromeTheme.inkBoost * 0.714  // reference separation
        for (token, delta) in deltas {
            XCTAssertGreaterThan(
                delta, target * 0.92,
                "\(token) paints a hairline at \(delta), under the \(target) every theme should reach")
        }
        XCTAssertEqual(deltas.count, ThemeCatalog.bundled.count)
    }

    /// A theme whose foreground and background are well separated must be left exactly as it was, or
    /// normalising becomes a global brightening wearing a per-theme disguise.
    func test_aWellSeparatedTheme_isNotScaled() {
        XCTAssertEqual(ChromeThemeDeriver.fillScale(for: Theme.rosePineZen), 1, accuracy: 0.0001)
    }

    /// And the cap holds, so a theme with almost no separation cannot demand an opaque border.
    func test_theScale_isCapped() {
        var flat = Theme.rosePineZen
        flat.foreground = flat.background
        XCTAssertEqual(ChromeThemeDeriver.fillScale(for: flat), 1.8, accuracy: 0.0001)
    }

    /// A role colour used as a fill has to go through `fill(_:alpha:)` so `fillScale` reaches it.
    /// A fixed accent fill beside a scaled foreground hover inverts on a narrow-separation theme:
    /// the active state reads fainter than the pointer merely being over the control.
    func test_aRoleTintedFill_isScaledLikeAForegroundOne() {
        var narrow = Theme.rosePineZen
        narrow.foreground = TerminalColor(red: 0x70, green: 0x70, blue: 0x70)  // close to its background
        let chrome = ChromeThemeDeriver.derive(from: narrow)
        XCTAssertGreaterThan(ChromeThemeDeriver.fillScale(for: narrow), 1, "precondition: it scales")

        let hover = chrome.fill(.hover).alphaComponent
        let active = chrome.fill(.active).alphaComponent
        let unscaled = chrome.tint(chrome.accent, alpha: ChromeTheme.FillLevel.active.alpha).alphaComponent

        XCTAssertGreaterThan(active, hover, "the active state must out-weigh hover")
        XCTAssertGreaterThan(unscaled, 0)
        XCTAssertLessThan(unscaled, hover, "and off the scaled path it would not, which is the bug")
    }

    // MARK: - the fill ladder

    /// **The ladder's whole promise.** Seven hand-tuned hover values is what a per-control number
    /// produced, and one of them inverted: an unscaled accent active fill read fainter than the
    /// pointer merely being over the control. Walking every bundled theme is what makes the promise
    /// checkable, because the scale is what breaks it and the scale is per theme.
    func test_everyBundledTheme_keepsTheFillLadderOrdered() throws {
        for entry in ThemeCatalog.bundled {
            let url = try XCTUnwrap(ThemeCatalog.bundledURL(for: entry.token))
            let terminal = GhosttyThemeParser.parse(
                try String(contentsOf: url, encoding: .utf8), fontName: "Menlo", fontSize: 12,
                fallback: Theme.rosePineZen)
            let chrome = ChromeThemeDeriver.derive(from: terminal)
            let painted = ChromeTheme.FillLevel.allCases.map { chrome.fill($0).alphaComponent }
            XCTAssertEqual(
                painted, painted.sorted(), "\(entry.token) paints the fill tiers out of order: \(painted)")
            XCTAssertEqual(Set(painted).count, painted.count, "\(entry.token) collapses two fill tiers")
        }
    }

    /// The one place a scaled fill faces an unscaled one: `selectionFill` is a focus fill sitting
    /// over `fill(.rest)` in every input and nav row. `tint(_:)` is deliberately off `fillScale`, so
    /// this pair is the only one the ladder cannot guarantee — it gets a test instead of an
    /// assumption. At the 1.8 cap the margin is still ~1.7x.
    func test_theSelectionFill_staysAboveTheRestFill_atEveryScale() {
        var flat = Theme.rosePineZen
        flat.foreground = flat.background  // forces the scale to its cap, the worst case for rest
        for theme in [Theme.rosePineZen, flat] {
            let chrome = ChromeThemeDeriver.derive(from: theme)
            XCTAssertGreaterThan(
                chrome.selectionFill.alphaComponent, chrome.fill(.rest).alphaComponent,
                "a focused input reads quieter than an unfocused one at scale "
                    + "\(ChromeThemeDeriver.fillScale(for: theme))")
        }
    }

    /// `tint(_:)` exists to stay off `fillScale`. If it ever picks the scale up, every selection row
    /// and icon badge lifts with it, which is the change this split was made to avoid.
    func test_aTint_isNotScaled() {
        var narrow = Theme.rosePineZen
        narrow.foreground = TerminalColor(red: 0x70, green: 0x70, blue: 0x70)
        let chrome = ChromeThemeDeriver.derive(from: narrow)
        XCTAssertGreaterThan(ChromeThemeDeriver.fillScale(for: narrow), 1, "precondition: it scales")
        XCTAssertEqual(
            chrome.tint(chrome.accent, alpha: 0.18).alphaComponent, 0.18 * ChromeTheme.inkBoost,
            accuracy: 0.001, "a tint has picked up fillScale")
    }
}
