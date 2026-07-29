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
final class ColorSchemeReportTests: XCTestCase {
    /// `CSI ? 997 ; 1 n` is dark, `; 2 n` is light (`Termio.colorSchemeReportLocked`).
    private static let darkReply = "\u{1b}[?997;1n"
    private static let lightReply = "\u{1b}[?997;2n"
    private static let darkBackground = TerminalColor(hex: "#191724")!
    private static let lightBackground = TerminalColor(hex: "#faf4ed")!

    func test_darkThemeReportsDark() throws {
        XCTAssertEqual(try schemeReply(background: Self.darkBackground), Self.darkReply)
    }

    func test_lightThemeReportsLight() throws {
        XCTAssertEqual(try schemeReply(background: Self.lightBackground), Self.lightReply)
    }

    /// A program repainting its own background with OSC 11 moves the answer with it, so a pane
    /// never reports one thing while rendering the other.
    ///
    /// Light theme repainted dark, deliberately, and not the other way around. libghostty's own
    /// default is light, so a test that ends on light passes just as happily when nothing is
    /// wired up at all — the first draft of this did exactly that, and stayed green with the
    /// whole feature deleted. Ending on dark is the only direction that can tell them apart.
    func test_osc11RepaintMovesTheReport() throws {
        let reply = try schemeReply(
            background: Self.lightBackground,
            // Repaint dark, then give the action a moment to cross to the main thread.
            preamble: ["printf '\\033]11;#191724\\007'", "sleep 0.5"],
            label: "osc11")
        XCTAssertEqual(reply, Self.darkReply)
    }

    /// Ask a real shell to send the query and hand back the raw reply libghostty wrote to the pty.
    private func schemeReply(
        background: TerminalColor, preamble: [String] = [], label: String = "theme"
    ) throws -> String {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 800, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.orderFront(nil)
        window.isReleasedWhenClosed = false
        defer { window.close() }

        let name = "\(label)-\(background.hex.dropFirst())"
        let out = NSTemporaryDirectory() + "zen307-reply-\(name).txt"
        let script = NSTemporaryDirectory() + "zen307-query-\(name).sh"
        try? FileManager.default.removeItem(atPath: out)
        // Raw mode with echo off, or the reply sits in the line discipline waiting for a newline
        // that a DSR answer never carries. `count` is the reply's exact width.
        let lines =
            ["stty raw -echo"] + preamble + [
                "printf '\\033[?996n'",
                "dd bs=1 count=9 2>/dev/null > '\(out)'",
            ]
        try lines.joined(separator: "\n").write(toFile: script, atomically: true, encoding: .utf8)

        let surface = GhosttySurface()
        surface.view.frame = NSRect(x: 0, y: 0, width: 780, height: 560)
        window.contentView?.addSubview(surface.view)
        surface.start(
            TerminalSurfaceConfig(
                command: "/bin/sh", args: [script], theme: Self.theme(background: background)))
        defer {
            surface.view.removeFromSuperview()
            surface.terminate()
        }
        try XCTSkipIf(surface.surfacePtr == nil, "ghostty_surface_new failed")

        // Poll rather than sleep a flat interval: the shell has to start first, and CI is slower
        // than this machine (ZEN-302). The runloop also carries libghostty's action callbacks.
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            if let data = FileManager.default.contents(atPath: out), data.count >= 9 {
                return String(decoding: data, as: UTF8.self)
            }
        }
        XCTFail("no color-scheme reply within 15s")
        return ""
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
