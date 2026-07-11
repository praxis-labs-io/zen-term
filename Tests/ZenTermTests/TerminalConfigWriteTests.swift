import CoreGraphics
import TerminalKit
import XCTest

@testable import ZenTerm

final class TerminalConfigWriteTests: XCTestCase {
    private var tempDirs: [URL] = []

    override func tearDownWithError() throws {
        for dir in tempDirs { try? FileManager.default.removeItem(at: dir) }
        tempDirs = []
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "zt-terminal-\(ProcessInfo.processInfo.globallyUniqueString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)
        return dir
    }

    func test_terminalScalars_writeAndReload() throws {
        let dir = try makeTempDir()
        try ConfigWriter.apply(
            scalars: [
                "font-family": "Menlo",
                "font-size": LayoutFormat.number(16),
                "cursor-style": LayoutFormat.cursorStyleToken(.bar),
                "cursor-style-blink": LayoutFormat.boolToken(false),
                "cursor-thickness": LayoutFormat.number(3),
                "macos-option-as-alt": LayoutFormat.boolToken(false),
                "scroll-multiplier": LayoutFormat.number(2),
                "shell": "/bin/zsh",
            ], configRoot: dir)

        let loaded = ConfigLoader.loadGeneralConfig(configRoot: dir)
        XCTAssertEqual(loaded.fontName, "Menlo")
        XCTAssertEqual(loaded.fontSize, 16, accuracy: 0.001)
        XCTAssertEqual(loaded.cursorStyle, .bar)
        XCTAssertEqual(loaded.cursorBlink, false)
        XCTAssertEqual(loaded.cursorThickness, 3)
        XCTAssertEqual(loaded.optionAsAlt, false)
        XCTAssertEqual(loaded.scrollMultiplier, 2, accuracy: 0.001)
        XCTAssertEqual(loaded.shell, "/bin/zsh")
    }

    func test_blankRemoval_fallsBackToBuiltIn() throws {
        let dir = try makeTempDir()
        try ConfigWriter.apply(scalars: ["font-family": "Menlo"], configRoot: dir)
        try ConfigWriter.apply(removals: ["font-family"], configRoot: dir)
        let loaded = ConfigLoader.loadGeneralConfig(configRoot: dir)
        XCTAssertEqual(loaded.fontName, GeneralConfig.builtIn.fontName)
    }
}
