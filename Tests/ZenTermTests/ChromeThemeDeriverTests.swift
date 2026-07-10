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

    func test_darkTheme_isDarkTrue_andInkIsByteIdenticalToHardcodedWhite() {
        let chrome = ChromeThemeDeriver.derive(from: Theme.rosePineMoon)
        XCTAssertTrue(chrome.isDark)
        assertEqualGray(chrome.ink(1, alpha: 0.55), NSColor(white: 1, alpha: 0.55))
    }

    func test_lightTheme_isDarkFalse_andInkFlipsToDarkOnLight() {
        var light = Theme.rosePineMoon
        light.background = TerminalColor(hex: "#faf4ed")!
        let chrome = ChromeThemeDeriver.derive(from: light)
        XCTAssertFalse(chrome.isDark)
        assertEqualGray(chrome.ink(1, alpha: 0.5), NSColor(white: 0, alpha: 0.5))
    }

    /// Compares two grayscale `NSColor`s by their white/alpha components, converting both
    /// through `.genericGray` first since `NSColor(white:alpha:)` isn't guaranteed to already
    /// be in that color space.
    private func assertEqualGray(
        _ lhs: NSColor, _ rhs: NSColor, file: StaticString = #filePath, line: UInt = #line
    ) {
        guard let lhsGray = lhs.usingColorSpace(.genericGray),
            let rhsGray = rhs.usingColorSpace(.genericGray)
        else {
            XCTFail("could not convert colors to genericGray", file: file, line: line)
            return
        }
        XCTAssertEqual(
            lhsGray.whiteComponent, rhsGray.whiteComponent, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(
            lhsGray.alphaComponent, rhsGray.alphaComponent, accuracy: 0.001, file: file, line: line)
    }
}
