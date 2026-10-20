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
        XCTAssertEqual(chrome.cursor, TerminalColor(hex: "#6b6790"))
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
        var recursored = Theme.rosePineZen
        recursored.cursor = TerminalColor(red: 255, green: 255, blue: 255)
        XCTAssertNotEqual(
            ChromeThemeDeriver.derive(from: Theme.rosePineZen),
            ChromeThemeDeriver.derive(from: recursored))
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
        XCTAssertEqual(overridden.cursor, base.cursor)
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
        XCTAssertEqual(ChromeThemeDeriver.fillScale(for: Theme.rosePineZen), 1, accuracy: 0.0001)
    }

    func test_theScale_isCapped() {
        var flat = Theme.rosePineZen
        flat.foreground = flat.background
        XCTAssertEqual(ChromeThemeDeriver.fillScale(for: flat), 1.8, accuracy: 0.0001)
    }

    func test_activeFill_isNeutral() {
        var narrow = Theme.rosePineZen
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
        var narrow = Theme.rosePineZen
        narrow.foreground = TerminalColor(red: 0x70, green: 0x70, blue: 0x70)
        let chrome = ChromeThemeDeriver.derive(from: narrow)
        XCTAssertGreaterThan(ChromeThemeDeriver.fillScale(for: narrow), 1, "precondition: it scales")
        XCTAssertEqual(
            chrome.tint(chrome.accent, alpha: 0.18).alphaComponent, 0.18 * ChromeTheme.inkBoost,
            accuracy: 0.001, "a tint has picked up fillScale")
    }

    private func bundledTerminals() throws -> [(token: String, terminal: TerminalTheme)] {
        try ThemeCatalog.bundled.map { entry in
            let url = try XCTUnwrap(ThemeCatalog.bundledURL(for: entry.token))
            let terminal = GhosttyThemeParser.parse(
                try String(contentsOf: url, encoding: .utf8), fontName: "Menlo", fontSize: 12,
                fallback: Theme.rosePineZen)
            return (entry.token, terminal)
        }
    }
}
