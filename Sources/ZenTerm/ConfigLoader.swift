import AppLog
import Foundation
import TerminalKit

/// The `~/.config/zen-term/` config layer. For ZEN-27 it loads only the theme file; later
/// tickets (workspaces, general config) extend it. Never throws to callers and never crashes:
/// a missing file yields the built-in default, an unreadable one logs and falls back, and a
/// partial/typo'd file falls back per-key inside `GhosttyThemeParser`.
enum ConfigLoader {
    #if DEBUG
        /// Test-only override for `defaultRoot`, so a settings/commit test can sandbox the config
        /// directory to a temp path. Set via env would be unreliable — `ProcessInfo.environment`
        /// caches, so a `setenv` after first access is invisible; this is the deterministic seam,
        /// mirroring `Theme.setCurrentForTesting`. Compiled out of release builds entirely.
        static var defaultRootOverrideForTesting: URL?
    #endif

    /// `$XDG_CONFIG_HOME/zen-term/` if set, else `~/.config/zen-term/` — ghostty's own
    /// resolution.
    static var defaultRoot: URL {
        #if DEBUG
            if let defaultRootOverrideForTesting { return defaultRootOverrideForTesting }
        #endif
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

    static func loadAppTheme(configRoot: URL = defaultRoot, general: GeneralConfig = .current) -> AppTheme {
        let builtIn = Theme.rosePineMoon

        var terminal: TerminalTheme
        if let themeURL = resolveThemeURL(configRoot: configRoot, general: general) {
            do {
                let text = try String(contentsOf: themeURL, encoding: .utf8)
                terminal = GhosttyThemeParser.parse(
                    text, fontName: builtIn.fontName, fontSize: builtIn.fontSize, fallback: builtIn)
            } catch {
                Log.warning(
                    "ConfigLoader: could not read \(themeURL.path): \(error) — using built-in theme",
                    category: .config)
                terminal = builtIn
            }
        } else {
            terminal = builtIn
        }

        // Font is a general-config knob, not a theme key (ghostty themes carry no font). Inject
        // it uniformly here so a custom font applies even with no theme file present.
        terminal.fontName = general.fontName
        terminal.fontSize = general.fontSize

        return AppTheme(terminal: terminal, chrome: ChromeThemeDeriver.derive(from: terminal))
    }

    /// Locate the active theme file, or nil to use the built-in default. A `theme = <name>`
    /// config key selects `themes/<name>`; with no key we fall back to a legacy single `theme`
    /// file. A named theme that doesn't exist warns and falls back to the built-in.
    private static func resolveThemeURL(configRoot: URL, general: GeneralConfig) -> URL? {
        if let name = general.themeName {
            let userURL = configRoot.appendingPathComponent("themes").appendingPathComponent(name)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: userURL.path, isDirectory: &isDir), !isDir.boolValue {
                return userURL
            }
            if let bundled = ThemeCatalog.bundledURL(for: name) { return bundled }
            Log.warning(
                "ConfigLoader: theme `\(name)` not found in user themes/ or the bundled catalog — using built-in theme",
                category: .config)
            return nil
        }
        let legacy = configRoot.appendingPathComponent("theme")
        return FileManager.default.fileExists(atPath: legacy.path) ? legacy : nil
    }

    static func loadGeneralConfig(configRoot: URL = defaultRoot) -> GeneralConfig {
        let configURL = configRoot.appendingPathComponent("config")
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            return .builtIn
        }
        do {
            let text = try String(contentsOf: configURL, encoding: .utf8)
            var config = GeneralConfigParser.parse(text, fallback: .builtIn)
            config.cursorShader = resolveShader(config.cursorShader)
            return config
        } catch {
            Log.warning(
                "ConfigLoader: could not read \(configURL.path): \(error) — using built-in config",
                category: .config)
            return .builtIn
        }
    }

    /// Resolve a bundled-shader name (from `cursor-shader = <name>`) to an absolute file path. A
    /// name with no bundled shader is logged and yields nil — bundled-only, so a path or an unknown
    /// name simply means no shader rather than loading anything un-vetted.
    private static func resolveShader(_ name: String?) -> String? {
        guard let name else { return nil }
        guard let url = ShaderCatalog.bundledURL(for: name) else {
            Log.warning(
                "ConfigLoader: cursor-shader `\(name)` is not a bundled shader — ignored",
                category: .config)
            return nil
        }
        return url.path
    }

    /// Load the hand-curated `workspaces` file (the `⌘⇧P` picker) from the config root. Absent
    /// or unreadable → an empty list; the parser drops any malformed section rather than throw. A
    /// workspace whose `path` doesn't resolve to a directory is kept (the dir may appear later)
    /// but logged, so a typo surfaces instead of silently opening a shell at a bad cwd.
    static func loadWorkspaces(configRoot: URL = defaultRoot) -> [Workspace] {
        let url = configRoot.appendingPathComponent("workspaces")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let workspaces: [Workspace]
        do {
            workspaces = WorkspacesParser.parse(try String(contentsOf: url, encoding: .utf8))
        } catch {
            Log.warning(
                "ConfigLoader: could not read \(url.path): \(error) — no workspaces loaded",
                category: .workspace)
            return []
        }
        // Diagnostic only, and one `stat` per workspace — unbounded on a network share, so it never
        // runs on the main queue (ZEN-90). The callers all present UI off the return value; nothing
        // waits on this.
        DispatchQueue.global(qos: .utility).async {
            for workspace in workspaces where !PathDisplay.isDirectory(workspace.path) {
                Log.warning(
                    "ConfigLoader: workspace `\(workspace.title)` path \(workspace.path.path) isn't a directory",
                    category: .workspace)
            }
        }
        return workspaces
    }
}
