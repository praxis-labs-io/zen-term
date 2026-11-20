import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

final class ChromeThemeDeriverTests: XCTestCase {
    func test_derivesRolesFromPaletteMatchingLegacyToastColors() {
        let chrome = ChromeThemeDeriver.derive(from: Theme.zenInk)
        XCTAssertEqual(chrome.background, TerminalColor(hex: "#0a0d14"))
        XCTAssertEqual(chrome.foreground, TerminalColor(hex: "#dce3ee"))
        XCTAssertEqual(chrome.info, TerminalColor(hex: "#6e9bff"))
        XCTAssertEqual(chrome.warning, TerminalColor(hex: "#ebc17a"))
        XCTAssertEqual(chrome.destructive, TerminalColor(hex: "#f2707a"))
        XCTAssertEqual(chrome.accent, TerminalColor(hex: "#6e9bff"))
        XCTAssertEqual(chrome.attention, TerminalColor(hex: "#5cc8e0"))
        XCTAssertEqual(chrome.positive, TerminalColor(hex: "#6ee6b8"))
        XCTAssertEqual(chrome.cursor, chrome.accent)
    }

    func test_chromeThemeStaysEquatable_acrossAllFields() {
        XCTAssertEqual(
            ChromeThemeDeriver.derive(from: Theme.zenInk),
            ChromeThemeDeriver.derive(from: Theme.zenInk))
        var recolored = Theme.zenInk
        recolored.ansi[AccentSlot.themeDefault.ansiIndex] = TerminalColor(red: 255, green: 255, blue: 255)
        XCTAssertNotEqual(
            ChromeThemeDeriver.derive(from: Theme.zenInk),
            ChromeThemeDeriver.derive(from: recolored))
        var recursored = Theme.zenInk
        recursored.cursor = TerminalColor(red: 255, green: 255, blue: 255)
        XCTAssertNotEqual(
            ChromeThemeDeriver.derive(from: Theme.zenInk),
            ChromeThemeDeriver.derive(from: recursored))
    }

    func test_accentOverride_movesOnlyTheAccentRole() {
        let base = ChromeThemeDeriver.derive(from: Theme.zenInk)
        let overridden = ChromeThemeDeriver.derive(from: Theme.zenInk, accent: .magenta)

        XCTAssertEqual(overridden.accent, TerminalColor(hex: "#b58cff"))
        XCTAssertNotEqual(overridden.accent, base.accent)
        XCTAssertEqual(overridden.info, base.info)
        XCTAssertEqual(overridden.warning, base.warning)
        XCTAssertEqual(overridden.destructive, base.destructive)
        XCTAssertEqual(overridden.attention, base.attention)
        XCTAssertEqual(overridden.positive, base.positive)
        XCTAssertEqual(overridden.cursor, base.cursor)
        XCTAssertEqual(overridden.background, base.background)
        XCTAssertEqual(overridden.foreground, base.foreground)
    }

    func test_noAccentOverride_resolvesToTheDefaultSlot() {
        XCTAssertEqual(AccentSlot.themeDefault, .blue)
        XCTAssertEqual(
            ChromeThemeDeriver.derive(from: Theme.zenInk, accent: nil).accent,
            ChromeThemeDeriver.derive(from: Theme.zenInk, accent: AccentSlot.themeDefault).accent)
    }

    func test_everySlotResolvesToItsPaletteEntry() {
        for slot in AccentSlot.allCases {
            XCTAssertEqual(
                ChromeThemeDeriver.derive(from: Theme.zenInk, accent: slot).accent,
                Theme.zenInk.ansi[slot.ansiIndex],
                "\(slot.rawValue) resolved to the wrong palette entry")
        }
    }

    func test_slotBeyondAShortPalette_fallsBackToForeground() {
        var short = Theme.zenInk
        short.ansi = Array(short.ansi.prefix(8))
        XCTAssertEqual(
            ChromeThemeDeriver.derive(from: short, accent: .brightWhite).accent, short.foreground)
    }

    func test_inkIsThemeForegroundAtTheBoostedLevelAlpha() {
        let chrome = ChromeThemeDeriver.derive(from: Theme.zenInk)
        for level in ChromeTheme.InkLevel.allCases {
            assertEqualRGBA(
                chrome.ink(level),
                Theme.zenInk.foreground.nsColor
                    .withAlphaComponent(min(1, level.alpha * ChromeTheme.inkBoost)))
        }
    }

    func test_theBoost_clampsOnlyTheNormalLevel() {
        let chrome = ChromeThemeDeriver.derive(from: Theme.zenInk)
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
        let chrome = ChromeThemeDeriver.derive(from: Theme.zenInk)
        XCTAssertEqual(ChromeTheme.InkLevel.allCases.first, .faint)
        XCTAssertLessThan(
            chrome.ink(.faint).alphaComponent, chrome.ink(.muted).alphaComponent,
            "faint has collapsed into muted")
        XCTAssertLessThan(
            ChromeTheme.InkLevel.faint.alpha, 1 / ChromeTheme.inkBoost,
            "faint is above the clamp and paints opaque")
    }

    func test_aThemeSilentOnSelectedTextGetsItsOwnForeground() {
        XCTAssertNil(Theme.zenInk.selectionForeground)
        XCTAssertEqual(
            AppTheme(terminal: Theme.zenInk).terminal.selectionForeground,
            Theme.zenInk.foreground)
    }

    func test_aThemeThatNamesSelectedTextKeepsWhatItNamed() {
        var named = Theme.zenInk
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
        for (token, terminal) in try bundledTerminals() {
            let chrome = ChromeThemeDeriver.derive(from: terminal)
            let alpha = chrome.fill(alpha: ChromeTheme.border).alphaComponent
            let background = perceived(terminal.background)
            let painted = perceived(terminal.foreground) * alpha + background * (1 - alpha)
            deltas.append((token, abs(painted - background)))
        }
        let target = ChromeTheme.border * ChromeTheme.inkBoost * 0.714
        for (token, delta) in deltas {
            XCTAssertGreaterThan(
                delta, target * 0.92,
                "\(token) paints a hairline at \(delta), under the \(target) every theme should reach")
        }
        XCTAssertEqual(deltas.count, ThemeCatalog.bundled.count)
    }

    func test_everyBundledTheme_labelsItsAccentInTheHigherContrastInk_onRestAndHover() throws {
        var rest: [(token: String, ratio: Double)] = []
        var hover: [(token: String, ratio: Double)] = []
        for (token, terminal) in try bundledTerminals() {
            let chrome = ChromeThemeDeriver.derive(from: terminal)
            let other = chrome.onAccent == terminal.background ? terminal.foreground : terminal.background
            XCTAssertTrue(
                [terminal.background, terminal.foreground].contains(chrome.onAccent),
                "\(token) labels its accent in neither background nor foreground")
            let ratio = ChromeThemeDeriver.contrastRatio(chrome.onAccent, chrome.accent)
            XCTAssertGreaterThanOrEqual(
                ratio, ChromeThemeDeriver.contrastRatio(other, chrome.accent),
                "\(token) picked the lower-contrast ink for onAccent")
            rest.append((token, ratio))
            hover.append((token, ChromeThemeDeriver.contrastRatio(chrome.onAccent, try hoverFill(chrome, away: other))))
        }
        for (name, pairs) in [("rest", rest), ("hover", hover)] {
            let lowest = pairs.sorted { $0.ratio < $1.ratio }.prefix(5)
                .map { "\($0.token) \(String(format: "%.2f", $0.ratio))" }.joined(separator: ", ")
            XCTContext.runActivity(named: "lowest onAccent contrast, \(name)") { activity in
                activity.add(XCTAttachment(string: lowest))
            }
            XCTAssertGreaterThanOrEqual(
                pairs.map(\.ratio).min() ?? 0, 2.5, "\(name) onAccent contrast fell under the floor: \(lowest)")
            XCTAssertEqual(pairs.count, ThemeCatalog.bundled.count)
        }
    }

    private func hoverFill(_ chrome: ChromeTheme, away: TerminalColor) throws -> TerminalColor {
        let blended = try XCTUnwrap(
            ChromeTheme.surface(
                tint: chrome.tint(away, alpha: ChromeTheme.primaryHoverBlend), over: chrome.accent.nsColor
            ).usingColorSpace(.sRGB))
        func byte(_ component: CGFloat) -> UInt8 { UInt8((component * 255).rounded()) }
        return TerminalColor(
            red: byte(blended.redComponent), green: byte(blended.greenComponent), blue: byte(blended.blueComponent))
    }

    func test_contrastRatio_matchesWCAG() throws {
        let black = try XCTUnwrap(TerminalColor(hex: "#000000"))
        let white = try XCTUnwrap(TerminalColor(hex: "#ffffff"))
        let gray = try XCTUnwrap(TerminalColor(hex: "#777777"))
        XCTAssertEqual(ChromeThemeDeriver.contrastRatio(black, white), 21, accuracy: 0.001)
        XCTAssertEqual(ChromeThemeDeriver.contrastRatio(white, black), 21, accuracy: 0.001)
        XCTAssertEqual(ChromeThemeDeriver.contrastRatio(gray, gray), 1, accuracy: 0.001)
        XCTAssertEqual(ChromeThemeDeriver.contrastRatio(gray, white), 4.48, accuracy: 0.01)
    }

    func test_aWellSeparatedTheme_isNotScaled() {
        XCTAssertEqual(ChromeThemeDeriver.fillScale(for: Theme.zenInk), 1, accuracy: 0.0001)
    }

    func test_theScale_isCapped() {
        var flat = Theme.zenInk
        flat.foreground = flat.background
        XCTAssertEqual(ChromeThemeDeriver.fillScale(for: flat), 1.8, accuracy: 0.0001)
    }

    func test_activeFill_isNeutral() {
        var narrow = Theme.zenInk
        narrow.foreground = TerminalColor(red: 0x70, green: 0x70, blue: 0x70)
        let chrome = ChromeThemeDeriver.derive(from: narrow)
        XCTAssertGreaterThan(ChromeThemeDeriver.fillScale(for: narrow), 1, "precondition: it scales")

        let active = chrome.fill(.active)
        XCTAssertEqual(active.withAlphaComponent(1), chrome.foreground.nsColor, "current is neutral, never accent")
        XCTAssertGreaterThan(active.alphaComponent, chrome.fill(.hover).alphaComponent)
    }

    func test_everyBundledTheme_keepsTheFillLadderOrdered() throws {
        for (token, terminal) in try bundledTerminals() {
            let chrome = ChromeThemeDeriver.derive(from: terminal)
            let painted = ChromeTheme.FillLevel.allCases.map { chrome.fill($0).alphaComponent }
            XCTAssertEqual(
                painted, painted.sorted(), "\(token) paints the fill tiers out of order: \(painted)")
            XCTAssertEqual(Set(painted).count, painted.count, "\(token) collapses two fill tiers")
        }
    }

    func test_theShadowSolve_matchesTheCalibration() throws {
        let calibration: [(hex: String, overlay: CGFloat, float: CGFloat, modal: CGFloat)] = [
            ("#faf4ed", 0.0816, 0.1391, 0.2071),
            ("#8c8fa1", 0.1254, 0.2130, 0.3158),
            ("#2e3440", 0.18, 0.30, 0.38),
            ("#080808", 0.18, 0.30, 0.38),
        ]
        for row in calibration {
            let background = try XCTUnwrap(TerminalColor(hex: row.hex))
            XCTAssertEqual(
                ChromeThemeDeriver.shadowAlpha(on: background, tier: .overlay),
                row.overlay, accuracy: 0.0005, "\(row.hex) overlay")
            XCTAssertEqual(
                ChromeThemeDeriver.shadowAlpha(on: background, tier: .float),
                row.float, accuracy: 0.0005, "\(row.hex) float")
            XCTAssertEqual(
                ChromeThemeDeriver.shadowAlpha(on: background, tier: .modal),
                row.modal, accuracy: 0.0005, "\(row.hex) modal")
        }
    }

    func test_everyBundledTheme_ordersItsShadowTiers() throws {
        for (token, terminal) in try bundledTerminals() {
            let chrome = ChromeThemeDeriver.derive(from: terminal)
            let tiers: [FloatShadow.Tier] = [.overlay, .float, .modal]
            XCTAssertGreaterThan(chrome.shadowAlpha(.overlay), 0, "\(token) drops the overlay shadow")
            for (lower, upper) in zip(tiers, tiers.dropFirst()) {
                XCTAssertLessThanOrEqual(
                    chrome.shadowAlpha(lower), chrome.shadowAlpha(upper),
                    "\(token) puts \(lower) above \(upper)")
            }
            for tier in tiers {
                XCTAssertLessThanOrEqual(
                    chrome.shadowAlpha(tier), tier.maxAlpha, "\(token) exceeds the \(tier) cap")
            }
        }
    }

    func test_aTint_isNotScaled() {
        var narrow = Theme.zenInk
        narrow.foreground = TerminalColor(red: 0x70, green: 0x70, blue: 0x70)
        let chrome = ChromeThemeDeriver.derive(from: narrow)
        XCTAssertGreaterThan(ChromeThemeDeriver.fillScale(for: narrow), 1, "precondition: it scales")
        XCTAssertEqual(
            chrome.tint(chrome.accent, alpha: 0.18).alphaComponent, 0.18 * ChromeTheme.inkBoost,
            accuracy: 0.001, "a tint has picked up fillScale")
    }

    func test_everyBundledTheme_raisesEachTierByItsLighteningUntilThereIsNoRoomLeft() throws {
        let white = TerminalColor(red: 255, green: 255, blue: 255)
        for (token, terminal) in try bundledTerminals() {
            let chrome = ChromeThemeDeriver.derive(from: terminal)
            let window = ChromeThemeDeriver.lightness(of: terminal.background)
            let ceiling = ChromeThemeDeriver.lightness(of: terminal.background.isDark ? terminal.foreground : white)
            for tier in FloatShadow.Tier.allCases {
                let raised = try XCTUnwrap(rgb(chrome.raised(tier)))
                let gained = ChromeThemeDeriver.lightness(of: raised) - window
                let room = max(0, ceiling - window)
                let expected = min(
                    Double(tier.lightening), terminal.background.isDark ? room * ChromeThemeDeriver.inkClearance : room)
                XCTAssertEqual(
                    gained, expected, accuracy: 0.6,
                    "\(token) raises its \(tier) fill by \(gained) L*, not \(expected)")
            }
        }
    }

    func test_aDarkTheme_raisesEveryTierAboveTheWindow_overlayHighest() throws {
        let chrome = ChromeThemeDeriver.derive(from: Theme.zenInk)
        let lightness = try [FloatShadow.Tier.modal, .float, .overlay].map {
            ChromeThemeDeriver.lightness(of: try XCTUnwrap(rgb(chrome.raised($0))))
        }
        XCTAssertGreaterThan(lightness[0], ChromeThemeDeriver.lightness(of: Theme.zenInk.background))
        XCTAssertEqual(lightness, lightness.sorted(), "the tiers must lift modal, then float, then overlay")
        XCTAssertEqual(Set(lightness).count, 3, "two tiers collapsed onto one fill")
    }

    func test_aLightTheme_liftsTowardWhite_andAWhiteWindowStaysWhite() throws {
        var offWhite = Theme.zenInk
        offWhite.background = try XCTUnwrap(TerminalColor(hex: "#e1e2e7"))
        offWhite.foreground = try XCTUnwrap(TerminalColor(hex: "#3760bf"))
        let lifted = try XCTUnwrap(rgb(ChromeThemeDeriver.derive(from: offWhite).raised(.overlay)))
        XCTAssertGreaterThan(
            ChromeThemeDeriver.lightness(of: lifted), ChromeThemeDeriver.lightness(of: offWhite.background))

        var white = offWhite
        white.background = try XCTUnwrap(TerminalColor(hex: "#ffffff"))
        for tier in FloatShadow.Tier.allCases {
            XCTAssertEqual(rgb(ChromeThemeDeriver.derive(from: white).raised(tier)), white.background)
        }
    }

    func test_aLowContrastDarkTheme_neverLiftsItsFloatsOntoTheInkColor() throws {
        var murky = Theme.zenInk
        murky.background = try XCTUnwrap(TerminalColor(hex: "#202020"))
        murky.foreground = try XCTUnwrap(TerminalColor(hex: "#2e2e2e"))
        let raised = try XCTUnwrap(rgb(ChromeThemeDeriver.derive(from: murky).raised(.overlay)))
        let separation =
            ChromeThemeDeriver.lightness(of: murky.foreground) - ChromeThemeDeriver.lightness(of: murky.background)
        XCTAssertNotEqual(raised, murky.foreground, "the overlay paints the ink's own color")
        XCTAssertLessThanOrEqual(
            ChromeThemeDeriver.lightness(of: raised) - ChromeThemeDeriver.lightness(of: murky.background),
            separation * ChromeThemeDeriver.inkClearance + 0.5)
    }

    private func rgb(_ color: NSColor) -> TerminalColor? {
        guard let srgb = color.usingColorSpace(.sRGB) else { return nil }
        func byte(_ component: CGFloat) -> UInt8 { UInt8((component * 255).rounded()) }
        return TerminalColor(
            red: byte(srgb.redComponent), green: byte(srgb.greenComponent), blue: byte(srgb.blueComponent))
    }

    private func bundledTerminals() throws -> [(token: String, terminal: TerminalTheme)] {
        try ThemeCatalog.bundled.map { entry in
            let url = try XCTUnwrap(ThemeCatalog.bundledURL(for: entry.token))
            let terminal = GhosttyThemeParser.parse(
                try String(contentsOf: url, encoding: .utf8), fontName: "Menlo", fontSize: 12,
                fallback: Theme.zenInk)
            return (entry.token, terminal)
        }
    }
}
