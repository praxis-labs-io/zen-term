import AppKit
import XCTest

@testable import TerminalKit

final class ColorSchemeReportTests: XCTestCase {
    private static let darkReply = "\u{1b}[?997;1n"
    private static let lightReply = "\u{1b}[?997;2n"
    private static let darkBackground = TerminalColor(hex: "#191724")!
    private static let lightBackground = TerminalColor(hex: "#faf4ed")!

    func test_darkThemeReportsDark() throws {
        let replies = try schemeReplies(background: Self.darkBackground, queries: 1)
        XCTAssertEqual(replies.first, Self.darkReply)
    }

    // Cannot catch the feature missing: light is libghostty's default answer.
    func test_lightThemeReportsLight() throws {
        let replies = try schemeReplies(background: Self.lightBackground, queries: 1)
        XCTAssertEqual(replies.first, Self.lightReply)
    }

    func test_reportFollowsAnOsc11Repaint() throws {
        let replies = try schemeReplies(
            background: Self.darkBackground, queries: 2, repaintTo: Self.lightBackground)
        XCTAssertEqual(replies.count, 2)
        XCTAssertEqual(replies.first, Self.darkReply, "a dark theme must report dark to start")
        XCTAssertEqual(replies.last, Self.lightReply, "the repaint to light must move the report")
    }

    func test_steppedFontSizeSurvivesTheSchemePush() throws {
        let base = try schemeAndGrid(fontSize: 13)
        let stepped = try schemeAndGrid(fontSize: 26)
        XCTAssertEqual(base.scheme, Self.darkReply, "the base pane must still report dark")
        XCTAssertEqual(stepped.scheme, Self.darkReply, "the stepped pane must still report dark")
        XCTAssertLessThan(
            stepped.columns, base.columns,
            "a 26pt pane must render fewer columns than a 13pt one; equal means the config push "
                + "reset it to the theme's size")
    }

    private func schemeAndGrid(fontSize: CGFloat) throws -> (scheme: String, columns: Int) {
        let replies = try schemeReplies(
            background: Self.darkBackground, queries: 1, bornFontSize: fontSize, alsoQueryGrid: true)
        let grid = try XCTUnwrap(replies.last)
        let columns = try XCTUnwrap(
            grid.split(separator: ";").last.flatMap { Int($0.dropLast()) },
            "could not parse a column count from \(grid.debugDescription)")
        return (replies[0], columns)
    }

    private func schemeReplies(
        background: TerminalColor, queries: Int, repaintTo: TerminalColor? = nil,
        bornFontSize: CGFloat? = nil, alsoQueryGrid: Bool = false
    ) throws -> [String] {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 800, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.orderFront(nil)
        window.isReleasedWhenClosed = false
        defer { window.close() }

        let stem = NSTemporaryDirectory() + "zen307-\(UUID().uuidString)"
        let outputs = (0..<(queries + (alsoQueryGrid ? 1 : 0))).map { "\(stem)-reply\($0).txt" }
        let script = "\(stem).sh"
        let gridSettled = "\(stem)-grid-settled"
        defer {
            for path in outputs + [script, gridSettled] {
                try? FileManager.default.removeItem(atPath: path)
            }
        }

        var lines = ["stty raw -echo", "printf '\\033[?996n'", "dd bs=1 count=9 2>/dev/null > '\(outputs[0])'"]
        if let repaintTo, outputs.count > 1 {
            lines += [
                "printf '\\033]11;\(repaintTo.hex)\\007'",
                "i=0",
                "while [ $i -lt 200 ]; do",
                "  printf '\\033[?996n'",
                "  dd bs=1 count=9 2>/dev/null > '\(outputs[1])'",
                "  case \"$(cat '\(outputs[1])')\" in *';2n') break;; esac",
                "  i=$((i+1))",
                "  sleep 0.05",
                "done",
            ]
        }
        if alsoQueryGrid {
            lines += [
                "i=0",
                "while [ $i -lt 20 ]; do",
                "  printf '\\033[18t'",
                "  reply=''",
                "  while :; do",
                "    ch=$(dd bs=1 count=1 2>/dev/null)",
                "    reply=\"${reply}${ch}\"",
                "    [ \"$ch\" = 't' ] && break",
                "  done",
                "  printf '%s' \"$reply\" > '\(outputs[outputs.count - 1])'",
                "  i=$((i+1))",
                "  sleep 0.05",
                "done",
                "touch '\(gridSettled)'",
            ]
        }
        try lines.joined(separator: "\n").write(toFile: script, atomically: true, encoding: .utf8)

        let surface = GhosttySurface()
        surface.view.frame = NSRect(x: 0, y: 0, width: 780, height: 560)
        window.contentView?.addSubview(surface.view)
        surface.start(
            TerminalSurfaceConfig(
                command: "/bin/sh", args: [script], fontSize: bornFontSize,
                theme: Self.theme(background: background)))
        defer {
            surface.view.removeFromSuperview()
            surface.terminate()
        }
        try XCTSkipIf(surface.surfacePtr == nil, "ghostty_surface_new failed")

        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            let data = outputs.map { FileManager.default.contents(atPath: $0) ?? Data() }
            guard data.allSatisfy({ $0.count >= 9 }) else { continue }
            if alsoQueryGrid, data[data.count - 1].last != UInt8(ascii: "t") { continue }
            if alsoQueryGrid, !FileManager.default.fileExists(atPath: gridSettled) { continue }
            if repaintTo != nil, String(decoding: data[data.count - 1], as: UTF8.self) != Self.lightReply,
                Date() < deadline.addingTimeInterval(-1)
            {
                continue
            }
            return data.map { String(decoding: $0, as: UTF8.self) }
        }
        XCTFail("no color-scheme reply within 30s")
        return []
    }

    private static func theme(background: TerminalColor) -> TerminalTheme {
        TerminalTheme(
            fontName: "Menlo", fontSize: 13,
            background: background,
            foreground: TerminalColor(hex: "#e0def4")!,
            cursor: TerminalColor(hex: "#e0def4")!,
            selectionBackground: TerminalColor(hex: "#403d52")!,
            ansi: (0..<16).map { _ in TerminalColor(hex: "#908caa")! })
    }
}
