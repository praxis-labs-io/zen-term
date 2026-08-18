import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

final class ChromeThemeDeriverTests: XCTestCase {
    func test_derivesRolesFromPaletteMatchingLegacyToastColors() {
        let chrome = ChromeThemeDeriver.derive(from: Theme.rosePineDarker)
        XCTAssertEqual(chrome.background, TerminalColor(hex: "#191724"))
        XCTAssertEqual(chrome.foreground, TerminalColor(hex: "#e0def4"))
        XCTAssertEqual(chrome.info, TerminalColor(hex: "#9ccfd8"))  // foam / palette[4]
        XCTAssertEqual(chrome.warning, TerminalColor(hex: "#f6c177"))  // gold / palette[3]
        XCTAssertEqual(chrome.destructive, TerminalColor(hex: "#eb6f92"))  // love / palette[1]
        XCTAssertEqual(chrome.accent, TerminalColor(hex: "#c4a7e7"))  // iris / palette[5]
        XCTAssertEqual(chrome.attention, TerminalColor(hex: "#ea9a97"))  // rose / palette[6]
        XCTAssertEqual(chrome.positive, TerminalColor(hex: "#3e8fb0"))  // pine / palette[2] (ANSI green)
        // muted = foreground (#e0def4 = 224,222,244) blended over background (#191724 =
        // 25,23,36) at 0.55: round(fg*0.55 + bg*0.45) per channel.
        //   R: 224*0.55 + 25*0.45 = 123.2 + 11.25 = 134.45 -> 134
        //   G: 222*0.55 + 23*0.45 = 122.1 + 10.35 = 132.45 -> 132
        //   B: 244*0.55 + 36*0.45 = 134.2 + 16.2  = 150.4  -> 150
        XCTAssertEqual(chrome.muted, TerminalColor(red: 134, green: 132, blue: 150))
    }

    func test_derivesAllSevenSyntaxRolesFromPalette() {
        let chrome = ChromeThemeDeriver.derive(from: Theme.rosePineDarker)
        XCTAssertEqual(chrome.synKeyword, TerminalColor(hex: "#c4a7e7"))  // iris / palette[5]
        XCTAssertEqual(chrome.synString, TerminalColor(hex: "#3e8fb0"))  // pine / palette[2]
        XCTAssertEqual(chrome.synNumber, TerminalColor(hex: "#f6c177"))  // gold / palette[3]
        XCTAssertEqual(chrome.synType, TerminalColor(hex: "#ea9a97"))  // rose / palette[6]
        XCTAssertEqual(chrome.synFunction, TerminalColor(hex: "#9ccfd8"))  // foam / palette[4]
        XCTAssertEqual(chrome.synPunctuation, TerminalColor(hex: "#eb6f92"))  // love / palette[1]
        // comment = foreground (#e0def4 = 224,222,244) blended over background (#191724 =
        // 25,23,36) at 0.45 (fainter than muted's 0.55): round(fg*0.45 + bg*0.55) per channel.
        //   R: 224*0.45 + 25*0.55 = 100.8 + 13.75 = 114.55 -> 115
        //   G: 222*0.45 + 23*0.55 =  99.9 + 12.65 = 112.55 -> 113
        //   B: 244*0.45 + 36*0.55 = 109.8 + 19.8  = 129.6  -> 130
        XCTAssertEqual(chrome.synComment, TerminalColor(red: 115, green: 113, blue: 130))
    }

    func test_chromeThemeStaysEquatable_acrossAllFields() {
        // A round-trip equality that touches every stored field, including the seven new syntax roles —
        // guards the synthesized `Equatable` conformance the row model relies on.
        XCTAssertEqual(
            ChromeThemeDeriver.derive(from: Theme.rosePineDarker),
            ChromeThemeDeriver.derive(from: Theme.rosePineDarker))
        var recolored = Theme.rosePineDarker
        recolored.ansi[5] = TerminalColor(red: 255, green: 255, blue: 255)  // shifts synKeyword (slot 5) alone
        XCTAssertNotEqual(
            ChromeThemeDeriver.derive(from: Theme.rosePineDarker),
            ChromeThemeDeriver.derive(from: recolored))
    }

    /// `accent-color` repoints the accent role and nothing else. The "nothing else" half
    /// is the one that can rot silently: accent is aliased to a slot other roles also read, so a
    /// deriver change could drag `info` or `attention` along with it and still look plausible.
    func test_accentOverride_movesOnlyTheAccentRole() {
        let base = ChromeThemeDeriver.derive(from: Theme.rosePineDarker)
        let overridden = ChromeThemeDeriver.derive(from: Theme.rosePineDarker, accent: .brightGreen)

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

    /// The diff viewer's syntax roles do not follow the accent picker. `synKeyword` is
    /// `slot(5)`, the same slot accent defaults to, so today they are the same color by
    /// coincidence and the coupling is invisible. Repointing the chrome's primary must not
    /// recolor code: a keyword is a token role, not a taste. This is the assertion that makes the
    /// coincidence deliberate, and it can only be written on a branch that has the syntax roles.
    func test_accentOverride_leavesTheSyntaxRolesWhereTheyAre() {
        let base = ChromeThemeDeriver.derive(from: Theme.rosePineDarker)
        let overridden = ChromeThemeDeriver.derive(from: Theme.rosePineDarker, accent: .brightGreen)

        XCTAssertEqual(overridden.synKeyword, base.synKeyword)
        XCTAssertEqual(overridden.synKeyword, TerminalColor(hex: "#c4a7e7"))  // still iris / palette[5]
        XCTAssertEqual(overridden.synString, base.synString)
        XCTAssertEqual(overridden.synComment, base.synComment)
        XCTAssertEqual(overridden.synNumber, base.synNumber)
        XCTAssertEqual(overridden.synType, base.synType)
        XCTAssertEqual(overridden.synFunction, base.synFunction)
        XCTAssertEqual(overridden.synPunctuation, base.synPunctuation)
    }

    /// An unset key has to derive exactly what it always did, or the setting silently recolors the
    /// chrome for every user who never opened it.
    func test_noAccentOverride_derivesTheHistoricalSlotFive() {
        XCTAssertEqual(
            ChromeThemeDeriver.derive(from: Theme.rosePineDarker, accent: nil).accent,
            ChromeThemeDeriver.derive(from: Theme.rosePineDarker, accent: .magenta).accent)
    }

    /// Every slot has to name the ANSI entry the palette actually put there — an off-by-one here
    /// would hand the user a color under the wrong name, which no assertion elsewhere would catch.
    func test_everySlotResolvesToItsPaletteEntry() {
        for slot in AccentSlot.allCases {
            XCTAssertEqual(
                ChromeThemeDeriver.derive(from: Theme.rosePineDarker, accent: slot).accent,
                Theme.rosePineDarker.ansi[slot.ansiIndex],
                "\(slot.rawValue) resolved to the wrong palette entry")
        }
    }

    /// A hand-written theme file may declare fewer than 16 entries; a high slot must fall back, not
    /// trap. `slot(_:)` already did this for the fixed roles — the override must not bypass it.
    func test_slotBeyondAShortPalette_fallsBackToForeground() {
        var short = Theme.rosePineDarker
        short.ansi = Array(short.ansi.prefix(8))
        XCTAssertEqual(
            ChromeThemeDeriver.derive(from: short, accent: .brightWhite).accent, short.foreground)
    }

    func test_inkIsThemeForegroundAtBoostedAlpha() {
        let chrome = ChromeThemeDeriver.derive(from: Theme.rosePineDarker)
        let expected = min(1, 0.55 * ChromeTheme.inkBoost)
        assertEqualRGBA(
            chrome.ink(alpha: 0.55),
            Theme.rosePineDarker.foreground.nsColor.withAlphaComponent(expected))
    }

    func test_aThemeSilentOnSelectedTextGetsItsOwnForeground() {
        XCTAssertNil(Theme.rosePineDarker.selectionForeground)  // the file names no such key
        XCTAssertEqual(
            AppTheme(terminal: Theme.rosePineDarker).terminal.selectionForeground,
            Theme.rosePineDarker.foreground)
    }

    func test_aThemeThatNamesSelectedTextKeepsWhatItNamed() {
        var named = Theme.rosePineDarker
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
}
