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
        XCTAssertEqual(chrome.positive, TerminalColor(hex: "#3e8fb0"))  // pine / palette[2] (ANSI green)
        // muted = foreground (#e0def4 = 224,222,244) blended over background (#191724 =
        // 25,23,36) at 0.55: round(fg*0.55 + bg*0.45) per channel.
        //   R: 224*0.55 + 25*0.45 = 123.2 + 11.25 = 134.45 -> 134
        //   G: 222*0.55 + 23*0.45 = 122.1 + 10.35 = 132.45 -> 132
        //   B: 244*0.55 + 36*0.45 = 134.2 + 16.2  = 150.4  -> 150
        XCTAssertEqual(chrome.muted, TerminalColor(red: 134, green: 132, blue: 150))
    }

    func test_derivesAllSevenSyntaxRolesFromPalette() {
        let chrome = ChromeThemeDeriver.derive(from: Theme.rosePineMoon)
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
            ChromeThemeDeriver.derive(from: Theme.rosePineMoon),
            ChromeThemeDeriver.derive(from: Theme.rosePineMoon))
        var recolored = Theme.rosePineMoon
        recolored.ansi[5] = TerminalColor(red: 255, green: 255, blue: 255)  // shifts synKeyword (slot 5) alone
        XCTAssertNotEqual(
            ChromeThemeDeriver.derive(from: Theme.rosePineMoon),
            ChromeThemeDeriver.derive(from: recolored))
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
