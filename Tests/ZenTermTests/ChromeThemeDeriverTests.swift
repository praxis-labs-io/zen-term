import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

final class ChromeThemeDeriverTests: XCTestCase {
    func test_derivesRolesFromPaletteMatchingLegacyToastColors() {
        let chrome = ChromeThemeDeriver.derive(from: Theme.rosePineMoon)
        XCTAssertEqual(chrome.background, TerminalColor(hex: "#191724"))
        XCTAssertEqual(chrome.foreground, TerminalColor(hex: "#e0def4"))
        XCTAssertEqual(chrome.info, TerminalColor(hex: "#9ccfd8"))  // foam / palette[4]
        XCTAssertEqual(chrome.warning, TerminalColor(hex: "#f6c177"))  // gold / palette[3]
        XCTAssertEqual(chrome.destructive, TerminalColor(hex: "#eb6f92"))  // love / palette[1]
        XCTAssertEqual(chrome.accent, TerminalColor(hex: "#c4a7e7"))  // iris / palette[5]
        XCTAssertEqual(chrome.attention, TerminalColor(hex: "#ea9a97"))  // rose / palette[6]
        // muted = foreground (#e0def4 = 224,222,244) blended over background (#191724 =
        // 25,23,36) at 0.55: round(fg*0.55 + bg*0.45) per channel.
        //   R: 224*0.55 + 25*0.45 = 123.2 + 11.25 = 134.45 -> 134
        //   G: 222*0.55 + 23*0.45 = 122.1 + 10.35 = 132.45 -> 132
        //   B: 244*0.55 + 36*0.45 = 134.2 + 16.2  = 150.4  -> 150
        XCTAssertEqual(chrome.muted, TerminalColor(red: 134, green: 132, blue: 150))
    }

    /// `accent-color` repoints the accent role and nothing else (ZEN-255). The "nothing else" half
    /// is the one that can rot silently: accent is aliased to a slot other roles also read, so a
    /// deriver change could drag `info` or `attention` along with it and still look plausible.
    func test_accentOverride_movesOnlyTheAccentRole() {
        let base = ChromeThemeDeriver.derive(from: Theme.rosePineMoon)
        let overridden = ChromeThemeDeriver.derive(from: Theme.rosePineMoon, accent: .brightGreen)

        XCTAssertEqual(overridden.accent, TerminalColor(hex: "#3e8fb0"))  // palette[10]
        XCTAssertNotEqual(overridden.accent, base.accent)
        XCTAssertEqual(overridden.info, base.info)
        XCTAssertEqual(overridden.warning, base.warning)
        XCTAssertEqual(overridden.destructive, base.destructive)
        XCTAssertEqual(overridden.attention, base.attention)
        XCTAssertEqual(overridden.muted, base.muted)
        XCTAssertEqual(overridden.background, base.background)
        XCTAssertEqual(overridden.foreground, base.foreground)
    }

    /// An unset key has to derive exactly what it always did, or the setting silently recolors the
    /// chrome for every user who never opened it.
    func test_noAccentOverride_derivesTheHistoricalSlotFive() {
        XCTAssertEqual(
            ChromeThemeDeriver.derive(from: Theme.rosePineMoon, accent: nil).accent,
            ChromeThemeDeriver.derive(from: Theme.rosePineMoon, accent: .magenta).accent)
    }

    /// Every slot has to name the ANSI entry the palette actually put there — an off-by-one here
    /// would hand the user a color under the wrong name, which no assertion elsewhere would catch.
    func test_everySlotResolvesToItsPaletteEntry() {
        for slot in AccentSlot.allCases {
            XCTAssertEqual(
                ChromeThemeDeriver.derive(from: Theme.rosePineMoon, accent: slot).accent,
                Theme.rosePineMoon.ansi[slot.ansiIndex],
                "\(slot.rawValue) resolved to the wrong palette entry")
        }
    }

    /// A hand-written theme file may declare fewer than 16 entries; a high slot must fall back, not
    /// trap. `slot(_:)` already did this for the fixed roles — the override must not bypass it.
    func test_slotBeyondAShortPalette_fallsBackToForeground() {
        var short = Theme.rosePineMoon
        short.ansi = Array(short.ansi.prefix(8))
        XCTAssertEqual(
            ChromeThemeDeriver.derive(from: short, accent: .brightWhite).accent, short.foreground)
    }

    func test_inkIsThemeForegroundAtBoostedAlpha() {
        let chrome = ChromeThemeDeriver.derive(from: Theme.rosePineMoon)
        let expected = min(1, 0.55 * ChromeTheme.inkBoost)
        assertEqualRGBA(
            chrome.ink(alpha: 0.55),
            Theme.rosePineMoon.foreground.nsColor.withAlphaComponent(expected))
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
