import AppKit
import XCTest

@testable import TerminalKit

/// What a surface answers when a program asks whether it is running light or dark (ZEN-307).
///
/// Driven through a real surface and a real shell, because there is no smaller way to see it: the
/// reply is assembled inside libghostty from state that three separate pieces have to agree on
/// (`set_color_scheme`, the config reload it triggers, and the conditional theme pair that lets
/// the reload carry the scheme). Asserting any one of them in isolation passes while the terminal
/// still reports the wrong thing, which is exactly what shipped before this.
///
/// Nobody looks at a DSR reply, so nothing here would be caught by eye. That is what earns it a
/// test rather than a runbook line.
///
/// **Light is libghostty's default, so no assertion of light can prove anything on its own.** A
/// test that ends on light stays green with this whole feature deleted. Every test here is either
/// anchored on dark or asserts a transition whose dark half does the work; the one light-theme
/// case is kept for what it *can* catch and is labelled with what it cannot.
final class ColorSchemeReportTests: XCTestCase {
    /// `CSI ? 997 ; 1 n` is dark, `; 2 n` is light (`Termio.colorSchemeReportLocked`).
    private static let darkReply = "\u{1b}[?997;1n"
    private static let lightReply = "\u{1b}[?997;2n"
    private static let darkBackground = TerminalColor(hex: "#191724")!
    private static let lightBackground = TerminalColor(hex: "#faf4ed")!

    func test_darkThemeReportsDark() throws {
        let replies = try schemeReplies(background: Self.darkBackground, queries: 1)
        XCTAssertEqual(replies.first, Self.darkReply)
    }

    /// Guards an inverted or mis-thresholded `TerminalColor.isDark`, which is the failure this can
    /// catch. It cannot catch the feature being absent: light is what libghostty answers when
    /// nothing is wired up, so this stays green in that case. `test_darkThemeReportsDark` and
    /// `test_reportFollowsAnOsc11Repaint` are the ones that fail then.
    func test_lightThemeReportsLight() throws {
        let replies = try schemeReplies(background: Self.lightBackground, queries: 1)
        XCTAssertEqual(replies.first, Self.lightReply)
    }

    /// A program repainting its own background with OSC 11 moves the answer with it, so a pane
    /// never reports one thing while rendering the other.
    ///
    /// Both directions from one surface: a dark theme has to report dark first, and only then does
    /// the repaint to light mean anything. The dark half is what fails if the feature regresses.
    func test_reportFollowsAnOsc11Repaint() throws {
        let replies = try schemeReplies(
            background: Self.darkBackground, queries: 2, repaintTo: Self.lightBackground)
        XCTAssertEqual(replies.count, 2)
        XCTAssertEqual(replies.first, Self.darkReply, "a dark theme must report dark to start")
        XCTAssertEqual(replies.last, Self.lightReply, "the repaint to light must move the report")
    }

    /// A pane opened at a stepped font size keeps it *and* reports its scheme, in one surface.
    ///
    /// These two have to be asserted together or neither means anything. Reporting the scheme
    /// requires a config push, and a config push is what reset the font size (ZEN-224): the first
    /// version of this feature shipped the report working and the size silently dropped. Assert
    /// the size alone and a regression that stops pushing config passes; assert the scheme alone
    /// and the size regression comes back. The pair pins the interaction.
    ///
    /// Column counts rather than a fixed geometry, so this does not depend on the machine's font
    /// metrics: a bigger font in the same view is fewer columns, whatever the absolute numbers.
    func test_steppedFontSizeSurvivesTheSchemePush() throws {
        let base = try schemeAndGrid(fontSize: 13)
        let stepped = try schemeAndGrid(fontSize: 26)
        XCTAssertEqual(base.scheme, Self.darkReply, "the base pane must still report dark")
        XCTAssertEqual(stepped.scheme, Self.darkReply, "the stepped pane must still report dark")
        XCTAssertLessThan(
            stepped.columns, base.columns,
            "a 26pt pane must render fewer columns than a 13pt one; equal means the config push "
                + "reset it to the theme's size (ZEN-224)")
    }

    /// Ask one surface for both its color scheme and its grid size.
    private func schemeAndGrid(fontSize: CGFloat) throws -> (scheme: String, columns: Int) {
        let replies = try schemeReplies(
            background: Self.darkBackground, queries: 1, bornFontSize: fontSize, alsoQueryGrid: true)
        let grid = try XCTUnwrap(replies.last)
        // `CSI 8 ; rows ; cols t`
        let columns = try XCTUnwrap(
            grid.split(separator: ";").last.flatMap { Int($0.dropLast()) },
            "could not parse a column count from \(grid.debugDescription)")
        return (replies[0], columns)
    }

    /// Run a shell that queries the color scheme, optionally repaints the background with OSC 11
    /// between queries, and hand back the raw replies libghostty wrote to the pty.
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

        // UUID-scoped, matching the temp paths under Tests/ZenTermTests. Two `swift test` runs on
        // this checkout at once is routine, and fixed names let them read each other's replies.
        let stem = NSTemporaryDirectory() + "zen307-\(UUID().uuidString)"
        let outputs = (0..<(queries + (alsoQueryGrid ? 1 : 0))).map { "\(stem)-reply\($0).txt" }
        let script = "\(stem).sh"
        let gridSettled = "\(stem)-grid-settled"
        defer {
            for path in outputs + [script, gridSettled] {
                try? FileManager.default.removeItem(atPath: path)
            }
        }

        // Raw mode with echo off, or a reply sits in the line discipline waiting for a newline
        // that a DSR answer never carries. `count` is the reply's exact width.
        var lines = ["stty raw -echo", "printf '\\033[?996n'", "dd bs=1 count=9 2>/dev/null > '\(outputs[0])'"]
        if let repaintTo, outputs.count > 1 {
            // Re-query until the answer moves rather than sleeping a fixed interval. The repaint
            // has to cross to the main thread, push a scheme, come back as a config reload and
            // reach the io thread before the reply can change, and no fixed wait covers that on a
            // loaded machine (ZEN-302). A shell that keeps asking is its own synchronization; if
            // the answer never moves, the last reply is the wrong one and the assertion says so.
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
            // `CSI 18 t` reports the text area in characters, which is how many columns the font
            // actually in force yields for this view. The scheme reply can precede the renderer's
            // font-driven grid relayout, so sample through a bounded settling window rather than
            // treating the first geometry as final. The marker keeps the host poll from returning
            // while the shell is still replacing that reply.
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

        // Poll rather than sleep: the shell has to start first, and CI is slower than this machine
        // (ZEN-302). The runloop is also what carries libghostty's action callbacks to us.
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            let data = outputs.map { FileManager.default.contents(atPath: $0) ?? Data() }
            guard data.allSatisfy({ $0.count >= 9 }) else { continue }
            // The grid reply is variable width and terminated by `t`, so length alone would let a
            // half-written one through.
            if alsoQueryGrid, data[data.count - 1].last != UInt8(ascii: "t") { continue }
            if alsoQueryGrid, !FileManager.default.fileExists(atPath: gridSettled) { continue }
            // The last reply is rewritten in place until it settles, so let the retry loop finish
            // rather than reading the first value it happens to land.
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
