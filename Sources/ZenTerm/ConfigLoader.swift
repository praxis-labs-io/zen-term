import Foundation
import TerminalKit

/// The `~/.config/zen-term/` config layer. For ZEN-27 it loads only the theme file; later
/// tickets (projects, general config) extend it. Never throws to callers and never crashes:
/// a missing file yields the built-in default, an unreadable one logs and falls back, and a
/// partial/typo'd file falls back per-key inside `GhosttyThemeParser`.
enum ConfigLoader {
    /// `$XDG_CONFIG_HOME/zen-term/` if set, else `~/.config/zen-term/` — ghostty's own
    /// resolution.
    static var defaultRoot: URL {
        let base: URL
        let environment = ProcessInfo.processInfo.environment
        if let xdg = environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            base = URL(fileURLWithPath: xdg, isDirectory: true)
        } else {
            base = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".config", isDirectory: true)
        }
        return base.appendingPathComponent("zen-term", isDirectory: true)
    }

    static func loadAppTheme(configRoot: URL = defaultRoot) -> AppTheme {
        let builtIn = Theme.rosePineMoon
        let themeURL = configRoot.appendingPathComponent("theme")

        let terminal: TerminalTheme
        if FileManager.default.fileExists(atPath: themeURL.path) {
            do {
                let text = try String(contentsOf: themeURL, encoding: .utf8)
                terminal = GhosttyThemeParser.parse(
                    text, fontName: builtIn.fontName, fontSize: builtIn.fontSize, fallback: builtIn)
            } catch {
                NSLog("ConfigLoader: could not read \(themeURL.path): \(error) — using built-in theme")
                terminal = builtIn
            }
        } else {
            terminal = builtIn
        }

        return AppTheme(terminal: terminal, chrome: ChromeThemeDeriver.derive(from: terminal))
    }
}
