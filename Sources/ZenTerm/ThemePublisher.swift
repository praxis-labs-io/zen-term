import AppLog
import Foundation
import TerminalKit

// Writes `theme.json` for editors in panes; `docs/nvim-theme-protocol.md` is the contract.
enum ThemePublisher {
    // A fixed path, not per-pid: a tool float launches with no environment to carry one.
    static var stateURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ZenTerm", isDirectory: true)
            .appendingPathComponent("theme.json")
    }

    // Property names are the JSON keys, so renaming one is a wire change.
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

    // Serial, so writes land in the order the theme changed.
    private static let queue = DispatchQueue(label: "com.zenterm.theme-publisher")

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
        static func waitForPendingWritesForTesting() { queue.sync {} }
    #endif

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

    static func resolvingColorscheme(_ payload: Payload, configRoot: URL, themeName: String?) -> Payload {
        var payload = payload
        payload.nvimColorscheme = ConfigLoader.activeThemeURL(configRoot: configRoot, themeName: themeName)
            .flatMap(nvimColorscheme(inThemeAt:))
        return payload
    }

    // A second read, because `GhosttyThemeParser` drops the key as unknown.
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
