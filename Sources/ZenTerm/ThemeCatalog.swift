import Foundation

struct ThemeEntry: Equatable {
    enum Source: Equatable { case bundled, user }
    let name: String
    let displayName: String
    let isDark: Bool
    let source: Source
}

enum ThemeCatalog {
    /// Stays in step with `Theme.rosePineZen`.
    static let defaultThemeName = "rose-pine-zen"

    static let bundled: [(token: String, displayName: String, isDark: Bool)] = [
        (defaultThemeName, "Rosé Pine Zen", true),
        ("rose-pine", "Rosé Pine", true),
        ("rose-pine-moon", "Rosé Pine Moon", true),
        ("rose-pine-dawn", "Rosé Pine Dawn", false),
        ("flexoki-dark", "Flexoki Dark", true),
        ("flexoki-light", "Flexoki Light", false),
        ("catppuccin-latte", "Catppuccin Latte", false),
        ("catppuccin-frappe", "Catppuccin Frappé", true),
        ("catppuccin-macchiato", "Catppuccin Macchiato", true),
        ("catppuccin-mocha", "Catppuccin Mocha", true),
        ("tokyo-night", "Tokyo Night", true),
        ("tokyo-night-storm", "Tokyo Night Storm", true),
        ("tokyo-night-day", "Tokyo Night Day", false),
        ("tokyo-night-moon", "Tokyo Night Moon", true),
        ("nord", "Nord", true),
        ("nightfox", "Nightfox", true),
        ("carbonfox", "Carbonfox", true),
        ("duskfox", "Duskfox", true),
        ("nordfox", "Nordfox", true),
        ("terafox", "Terafox", true),
        ("dawnfox", "Dawnfox", false),
        ("dayfox", "Dayfox", false),
        ("gruvbox-dark", "Gruvbox Dark", true),
        ("gruvbox-light", "Gruvbox Light", false),
        ("dracula", "Dracula", true),
        ("solarized-dark", "Solarized Dark", true),
        ("solarized-light", "Solarized Light", false),
        ("everforest", "Everforest", true),
        ("everforest-light", "Everforest Light", false),
        ("kanagawa", "Kanagawa", true),
        ("kanagawabones", "Kanagawabones", true),
        ("neobones-dark", "Neobones Dark", true),
        ("neobones-light", "Neobones Light", false),
        ("seoulbones-dark", "Seoulbones Dark", true),
        ("seoulbones-light", "Seoulbones Light", false),
        ("duckbones", "Duckbones", true),
        ("github-dark-default", "GitHub Dark", true),
        ("github-dark-dimmed", "GitHub Dark Dimmed", true),
        ("github-dark-high-contrast", "GitHub Dark High Contrast", true),
        ("github-light-default", "GitHub Light", false),
        ("github-light-high-contrast", "GitHub Light High Contrast", false),
        ("kanso-zen", "Kanso Zen", true),
        ("kanso-ink", "Kanso Ink", true),
        ("kanso-mist", "Kanso Mist", true),
        ("kanso-pearl", "Kanso Pearl", false),
        ("gruvbox-material", "Gruvbox Material", true),
        ("gruvbox-material-dark", "Gruvbox Material Dark", true),
        ("gruvbox-material-light", "Gruvbox Material Light", false),
        ("iceberg-dark", "Iceberg Dark", true),
        ("iceberg-light", "Iceberg Light", false),
        ("jellybeans", "Jellybeans", true),
        ("moonfly", "Moonfly", true),
        ("kanagawa-dragon", "Kanagawa Dragon", true),
        ("kanagawa-lotus", "Kanagawa Lotus", false),
        ("monokai-pro", "Monokai Pro", true),
        ("monokai-pro-machine", "Monokai Pro Machine", true),
        ("monokai-pro-octagon", "Monokai Pro Octagon", true),
        ("monokai-pro-ristretto", "Monokai Pro Ristretto", true),
        ("monokai-pro-spectrum", "Monokai Pro Spectrum", true),
        ("monokai-pro-light", "Monokai Pro Light", false),
        ("monokai-pro-light-sun", "Monokai Pro Light Sun", false),
        ("melange-dark", "Melange Dark", true),
        ("melange-light", "Melange Light", false),
        ("oxocarbon", "Oxocarbon", true),
        ("vesper", "Vesper", true),
    ]

    /// Sorts with `localizedStandardCompare`, or "Rosé Pine" lands after "Z".
    static func entries(configRoot: URL = ConfigLoader.defaultRoot) -> [ThemeEntry] {
        var entries: [ThemeEntry] = []
        let userTokens = userThemeTokens(configRoot: configRoot)
        let userSet = Set(userTokens)
        let sorted = bundled.sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
        for entry in sorted where !userSet.contains(entry.token) {
            entries.append(
                ThemeEntry(name: entry.token, displayName: entry.displayName, isDark: entry.isDark, source: .bundled))
        }
        for token in userTokens {
            entries.append(ThemeEntry(name: token, displayName: token, isDark: true, source: .user))
        }
        return entries
    }

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

    static func bundledURL(for token: String) -> URL? {
        ZenTermResources.bundle.url(forResource: token, withExtension: "ghostty", subdirectory: "Themes")
    }
}
