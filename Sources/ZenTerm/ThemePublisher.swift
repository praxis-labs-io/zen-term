import AppLog
import Foundation
import TerminalKit

/// Publishes the resolved theme to `theme.json` so an editor running inside a pane can follow a
/// theme switch. `docs/nvim-theme-protocol.md` is the contract; `zen-theme.nvim` reads it.
enum ThemePublisher {
    /// `~/Library/Application Support/ZenTerm/theme.json`. A fixed path, unlike the per-pid nav
    /// socket: a tool float launches with no environment, so a reader cannot be handed a path.
    /// Two running instances are last-writer-wins, and a stale value self-corrects on the next
    /// theme change.
    static var stateURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ZenTerm", isDirectory: true)
            .appendingPathComponent("theme.json")
    }

    /// The published shape — property names are the JSON keys, so renaming one is a wire change.
    /// `dark` is the resolved background's own reading rather than the catalog's flag, so a user
    /// theme reports it as accurately as a bundled one.
    struct Payload: Encodable, Equatable, Sendable {
        let name: String
        let dark: Bool
        var nvimColorscheme: String?
        let background: String
        let foreground: String
        let cursor: String
        let selectionBackground: String
        let accent: String
        let ansi: [String]
    }

    /// Serial, so two writes land in the order the theme actually changed.
    private static let queue = DispatchQueue(label: "com.zenterm.theme-publisher")

    /// Snapshot the resolved theme on the main actor, then encode and write off it. Everything
    /// that touches the filesystem — resolving the theme file, reading its `nvim-colorscheme`,
    /// the write itself — runs on `queue`, because the chrome is the product and a stalled main
    /// thread is a beachball.
    @MainActor
    static func publish(
        theme: AppTheme = Theme.current, general: GeneralConfig = .current,
        configRoot: URL = ConfigLoader.defaultRoot, to url: URL = stateURL
    ) {
        let payload = payload(for: theme, themeName: general.themeName)
        let themeName = general.themeName
        queue.async { write(resolvingColorscheme(payload, configRoot: configRoot, themeName: themeName), to: url) }
    }

    #if DEBUG
        /// Test hook: block until the queued write lands. The publish is deliberately asynchronous,
        /// so a test asserting the file exists would otherwise race it.
        static func waitForPendingWritesForTesting() { queue.sync {} }
    #endif

    /// The payload bar `nvimColorscheme`, which only the theme file can answer. Pure: no
    /// filesystem, so it is safe on the main actor and directly assertable in a test.
    static func payload(for theme: AppTheme, themeName: String?) -> Payload {
        let terminal = theme.terminal
        return Payload(
            name: themeName ?? ThemeCatalog.defaultThemeName,
            dark: terminal.background.isDark,
            background: terminal.background.hex,
            foreground: terminal.foreground.hex,
            cursor: terminal.cursor.hex,
            selectionBackground: terminal.selectionBackground.hex,
            accent: theme.chrome.accent.hex,
            ansi: terminal.ansi.map(\.hex))
    }

    /// Fill in `nvimColorscheme` from the active theme file. Off-main only — it resolves the file
    /// and reads it.
    static func resolvingColorscheme(_ payload: Payload, configRoot: URL, themeName: String?) -> Payload {
        var payload = payload
        payload.nvimColorscheme = ConfigLoader.activeThemeURL(configRoot: configRoot, themeName: themeName)
            .flatMap(nvimColorscheme(inThemeAt:))
        return payload
    }

    /// The theme file's `nvim-colorscheme` value, or nil when it names none. `GhosttyThemeParser`
    /// drops the key as unknown, so this is a second read of the same file rather than a field on
    /// `TerminalTheme`: which colorscheme an editor should wear is no business of the seam.
    static func nvimColorscheme(inThemeAt url: URL) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), let equals = line.firstIndex(of: "=") else { continue }
            guard line[..<equals].trimmingCharacters(in: .whitespaces) == "nvim-colorscheme" else { continue }
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
        return nil
    }

    /// Write atomically so a reader watching the file never sees a half-written payload. Sorted
    /// keys so an unchanged theme produces an unchanged file, and a failure is logged and dropped:
    /// nothing in the app depends on the write landing.
    private static func write(_ payload: Payload, to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(payload).write(to: url, options: .atomic)
        } catch {
            Log.warning("ThemePublisher: could not write \(url.path): \(error)", category: .config)
        }
    }
}
