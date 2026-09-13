import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

final class ChromeThemeDeriverTests: XCTestCase {
    func test_derivesRolesFromPaletteMatchingLegacyToastColors() {
        let chrome = ChromeThemeDeriver.derive(from: Theme.rosePineZen)
        XCTAssertEqual(chrome.background, TerminalColor(hex: "#191724"))
        XCTAssertEqual(chrome.foreground, TerminalColor(hex: "#e0def4"))
        XCTAssertEqual(chrome.info, TerminalColor(hex: "#9ccfd8"))
        XCTAssertEqual(chrome.warning, TerminalColor(hex: "#f6c177"))
        XCTAssertEqual(chrome.destructive, TerminalColor(hex: "#eb6f92"))
        XCTAssertEqual(chrome.accent, TerminalColor(hex: "#9ccfd8"))
        XCTAssertEqual(chrome.attention, TerminalColor(hex: "#ea9a97"))
        XCTAssertEqual(chrome.positive, TerminalColor(hex: "#3e8fb0"))
        XCTAssertEqual(chrome.muted, TerminalColor(red: 134, green: 132, blue: 150))
    }

    func test_chromeThemeStaysEquatable_acrossAllFields() {
        XCTAssertEqual(
            ChromeThemeDeriver.derive(from: Theme.rosePineZen),
            ChromeThemeDeriver.derive(from: Theme.rosePineZen))
        var recolored = Theme.rosePineZen
        recolored.ansi[AccentSlot.themeDefault.ansiIndex] = TerminalColor(red: 255, green: 255, blue: 255)
        XCTAssertNotEqual(
            ChromeThemeDeriver.derive(from: Theme.rosePineZen),
            ChromeThemeDeriver.derive(from: recolored))
    }

    func test_accentOverride_movesOnlyTheAccentRole() {
        let base = ChromeThemeDeriver.derive(from: Theme.rosePineZen)
        let overridden = ChromeThemeDeriver.derive(from: Theme.rosePineZen, accent: .brightGreen)

        XCTAssertEqual(overridden.accent, TerminalColor(hex: "#3e8fb0"))
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

    func test_noAccentOverride_resolvesToTheDefaultSlot() {
        XCTAssertEqual(AccentSlot.themeDefault, .blue)
        XCTAssertEqual(
            ChromeThemeDeriver.derive(from: Theme.rosePineZen, accent: nil).accent,
            ChromeThemeDeriver.derive(from: Theme.rosePineZen, accent: AccentSlot.themeDefault).accent)
    }

    func test_everySlotResolvesToItsPaletteEntry() {
        for slot in AccentSlot.allCases {
            XCTAssertEqual(
                ChromeThemeDeriver.derive(from: Theme.rosePineZen, accent: slot).accent,
                Theme.rosePineZen.ansi[slot.ansiIndex],
                "\(slot.rawValue) resolved to the wrong palette entry")
        }
    }

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

    func test_theBoost_clampsOnlyTheNormalLevel() {
        let chrome = ChromeThemeDeriver.derive(from: Theme.rosePineZen)
        for level in ChromeTheme.InkLevel.allCases where level != .normal {
            XCTAssertLessThan(
                chrome.ink(level).alphaComponent, 1, "\(level) has been boosted into normal")
        }
        XCTAssertEqual(chrome.ink(.normal).alphaComponent, 1, accuracy: 0.0001)
    }

    func test_theInkLevels_areOrderedAndDistinct() {
        let alphas = ChromeTheme.InkLevel.allCases.map(\.alpha)
        XCTAssertEqual(alphas, alphas.sorted(), "declaration order is the weight order")
        XCTAssertEqual(Set(alphas).count, alphas.count, "two levels share an alpha")
        XCTAssertEqual(ChromeTheme.InkLevel.normal.alpha, 1, "normal is full strength or it is not normal")
        XCTAssertEqual(ChromeTheme.InkLevel.allCases.last, .normal, "normal is the top of the ramp")
    }

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
        XCTAssertNil(Theme.rosePineZen.selectionForeground)
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
        let target = ChromeTheme.border * ChromeTheme.inkBoost * 0.714
        for (token, delta) in deltas {
            XCTAssertGreaterThan(
                delta, target * 0.92,
                "\(token) paints a hairline at \(delta), under the \(target) every theme should reach")
        }
        XCTAssertEqual(deltas.count, ThemeCatalog.bundled.count)
    }

    func test_aWellSeparatedTheme_isNotScaled() {
        XCTAssertEqual(ChromeThemeDeriver.fillScale(for: Theme.rosePineZen), 1, accuracy: 0.0001)
    }

    func test_theScale_isCapped() {
        var flat = Theme.rosePineZen
        flat.foreground = flat.background
        XCTAssertEqual(ChromeThemeDeriver.fillScale(for: flat), 1.8, accuracy: 0.0001)
    }

    func test_aRoleTintedFill_isScaledLikeAForegroundOne() {
        var narrow = Theme.rosePineZen
        narrow.foreground = TerminalColor(red: 0x70, green: 0x70, blue: 0x70)
        let chrome = ChromeThemeDeriver.derive(from: narrow)
        XCTAssertGreaterThan(ChromeThemeDeriver.fillScale(for: narrow), 1, "precondition: it scales")

        let hover = chrome.fill(.hover).alphaComponent
        let active = chrome.fill(.active).alphaComponent
        let unscaled = chrome.tint(chrome.accent, alpha: ChromeTheme.FillLevel.active.alpha).alphaComponent

        XCTAssertGreaterThan(active, hover, "the active state must out-weigh hover")
        XCTAssertGreaterThan(unscaled, 0)
        XCTAssertLessThan(unscaled, hover, "and off the scaled path it would not, which is the bug")
    }

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

    func test_theSelectionFill_staysAboveTheRestFill_atEveryScale() {
        var flat = Theme.rosePineZen
        flat.foreground = flat.background
        for theme in [Theme.rosePineZen, flat] {
            let chrome = ChromeThemeDeriver.derive(from: theme)
            XCTAssertGreaterThan(
                chrome.selectionFill.alphaComponent, chrome.fill(.rest).alphaComponent,
                "a focused input reads quieter than an unfocused one at scale "
                    + "\(ChromeThemeDeriver.fillScale(for: theme))")
        }
    }

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
