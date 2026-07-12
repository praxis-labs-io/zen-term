import AppKit
import SwiftTerm
import XCTest

@testable import TerminalKit

/// Proves `applyAppearance` re-themes an already-running `SwiftTermSurface` in place
/// (ZEN-89 Task 1): a live surface started with one theme/behavior, then re-applied with a
/// different one, reflects the new colors and cursor style without being recreated.
final class SwiftTermSurfaceAppearanceTests: XCTestCase {
    private let themeA = TerminalTheme(
        fontName: "Menlo",
        fontSize: 13,
        background: TerminalColor(red: 0x10, green: 0x10, blue: 0x10),
        foreground: TerminalColor(red: 0xE0, green: 0xE0, blue: 0xE0),
        cursor: TerminalColor(red: 0xFF, green: 0x00, blue: 0x00),
        selectionBackground: TerminalColor(red: 0x20, green: 0x20, blue: 0x20),
        ansi: (0..<16).map { TerminalColor(red: UInt8($0), green: UInt8($0), blue: UInt8($0)) }
    )
    private let themeB = TerminalTheme(
        fontName: "Menlo",
        fontSize: 13,
        background: TerminalColor(red: 0xAB, green: 0xCD, blue: 0xEF),
        foreground: TerminalColor(red: 0x01, green: 0x02, blue: 0x03),
        cursor: TerminalColor(red: 0x00, green: 0xFF, blue: 0x00),
        selectionBackground: TerminalColor(red: 0x30, green: 0x40, blue: 0x50),
        ansi: (0..<16).map { TerminalColor(red: UInt8($0), green: UInt8($0), blue: UInt8($0)) }
    )
    private let behaviorA = TerminalBehavior(cursorStyle: .block, cursorBlink: true)
    private let behaviorB = TerminalBehavior(cursorStyle: .bar, cursorBlink: false)

    func test_applyAppearanceRethemesRunningSurfaceInPlace() throws {
        let surface = SwiftTermSurface()
        surface.start(
            TerminalSurfaceConfig(
                command: "/bin/sleep", args: ["100"], theme: themeA, behavior: behaviorA))

        let view = try XCTUnwrap(surface.view as? TerminalView)
        XCTAssertEqual(view.nativeBackgroundColor, themeA.background.nsColor)
        XCTAssertEqual(view.getTerminal().options.cursorStyle, .blinkBlock)

        surface.applyAppearance(theme: themeB, behavior: behaviorB)

        XCTAssertEqual(view.nativeBackgroundColor, themeB.background.nsColor)
        XCTAssertEqual(view.caretColor, themeB.cursor.nsColor)
        XCTAssertEqual(view.selectedTextBackgroundColor, themeB.selectionBackground.nsColor)
        XCTAssertEqual(view.getTerminal().options.cursorStyle, .steadyBar)

        surface.terminate()
    }
}
