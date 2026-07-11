import Foundation

/// One selectable theme in the picker: the built-in default (nil name = no `theme` key), a
/// bundled catalog entry, or a user file in `~/.config/zen-term/themes/`.
struct ThemeEntry: Equatable {
    enum Source: Equatable { case builtIn, bundled, user }
    /// Config token written as `theme = <name>`; nil for the built-in default (clears the key).
    let name: String?
    let displayName: String
    let isDark: Bool
    let source: Source
}

/// The theme picker's model: the built-in default, the bundled ghostty catalog (shipped as
/// resources), and any files the user dropped in `themes/`. A user file shadows a bundled entry
/// of the same token so a user can override a shipped theme.
enum ThemeCatalog {
    /// Bundled catalog. Each token has a `Themes/<token>.ghostty` resource (see Task 2 manifest).
    static let bundled: [(token: String, displayName: String, isDark: Bool)] = [
        ("rose-pine", "Rosé Pine", true),
        ("rose-pine-dawn", "Rosé Pine Dawn", false),
        ("catppuccin-latte", "Catppuccin Latte", false),
        ("catppuccin-frappe", "Catppuccin Frappé", true),
        ("catppuccin-macchiato", "Catppuccin Macchiato", true),
        ("catppuccin-mocha", "Catppuccin Mocha", true),
        ("tokyo-night", "Tokyo Night", true),
        ("tokyo-night-storm", "Tokyo Night Storm", true),
        ("tokyo-night-day", "Tokyo Night Day", false),
        ("nord", "Nord", true),
        ("gruvbox-dark", "Gruvbox Dark", true),
        ("dracula", "Dracula", true),
        ("solarized-dark", "Solarized Dark", true),
        ("everforest", "Everforest", true),
        ("kanagawa", "Kanagawa", true),
    ]

    /// Built-in default, then bundled entries (minus any shadowed by a user file), then user files.
    static func entries(configRoot: URL = ConfigLoader.defaultRoot) -> [ThemeEntry] {
        var entries: [ThemeEntry] = [
            ThemeEntry(name: nil, displayName: "Rosé Pine Moon", isDark: true, source: .builtIn)
        ]
        let userTokens = userThemeTokens(configRoot: configRoot)
        let userSet = Set(userTokens)
        for entry in bundled where !userSet.contains(entry.token) {
            entries.append(
                ThemeEntry(name: entry.token, displayName: entry.displayName, isDark: entry.isDark, source: .bundled))
        }
        for token in userTokens {
            // Display the raw token and assume dark (best-effort; a user light theme still works).
            entries.append(ThemeEntry(name: token, displayName: token, isDark: true, source: .user))
        }
        return entries
    }

    /// Basenames of the user's `themes/` files (skip dotfiles), sorted. Empty if the dir is absent.
    static func userThemeTokens(configRoot: URL) -> [String] {
        let dir = configRoot.appendingPathComponent("themes")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        return names.filter { name in
            guard !name.hasPrefix(".") else { return false }
            var isDir: ObjCBool = false
            let path = dir.appendingPathComponent(name).path
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && !isDir.boolValue
        }.sorted()
    }

    /// The bundled resource URL for a token, or nil if it isn't a bundled theme.
    static func bundledURL(for token: String) -> URL? {
        Bundle.module.url(forResource: token, withExtension: "ghostty", subdirectory: "Themes")
    }
}
