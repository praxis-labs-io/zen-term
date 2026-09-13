import AppLog
import Foundation
import TerminalKit

enum ConfigLoader {
    #if DEBUG
        /// Not an env var: `ProcessInfo.environment` caches, so a later `setenv` is invisible.
        static var defaultRootOverrideForTesting: URL?
    #endif

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

    @MainActor
    static func loadAppTheme(configRoot: URL = defaultRoot, general: GeneralConfig = .current) -> AppTheme {
        let builtIn = Theme.rosePineZen

        var terminal: TerminalTheme
        if let themeURL = activeThemeURL(configRoot: configRoot, themeName: general.themeName) {
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

        terminal.fontName = general.fontName
        terminal.fontSize = general.fontSize

        return AppTheme(terminal: terminal, accent: general.accentColor)
    }

    static func activeThemeURL(configRoot: URL, themeName: String?) -> URL? {
        if let name = themeName {
            if let url = namedThemeURL(configRoot: configRoot, name: name) { return url }
            Log.warning(
                "ConfigLoader: theme `\(name)` not found in user themes/ or the bundled catalog — using built-in theme",
                category: .config)
            return nil
        }
        let legacy = configRoot.appendingPathComponent("theme")
        if FileManager.default.fileExists(atPath: legacy.path) { return legacy }
        return namedThemeURL(configRoot: configRoot, name: ThemeCatalog.defaultThemeName)
    }

    private static func namedThemeURL(configRoot: URL, name: String) -> URL? {
        let userURL = configRoot.appendingPathComponent("themes").appendingPathComponent(name)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: userURL.path, isDirectory: &isDir), !isDir.boolValue {
            return userURL
        }
        return ThemeCatalog.bundledURL(for: name)
    }

    /// `@MainActor` because keymap assembly calls TIS, which kills the process off-main with no crash report.
    @MainActor
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

    static func loadWorkspaces(configRoot: URL = defaultRoot, completion: @escaping ([Workspace]) -> Void) {
        loadQueue.async {
            let workspaces = loadWorkspacesBlocking(configRoot: configRoot)
            DispatchQueue.main.async { completion(workspaces) }
            validationQueue.async { warnAboutMissingDirectories(workspaces) }
        }
    }

    private static let loadQueue = DispatchQueue(label: "com.zenterm.config-load", qos: .userInitiated)

    /// Separate from the load queue so a hung mount's `stat` cannot block the next load.
    private static let validationQueue = DispatchQueue(
        label: "com.zenterm.config-validate", qos: .utility)

    static func loadWorkspacesBlocking(configRoot: URL = defaultRoot) -> [Workspace] {
        let url = configRoot.appendingPathComponent("workspaces")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        do {
            return WorkspacesParser.parse(try String(contentsOf: url, encoding: .utf8))
        } catch {
            Log.warning(
                "ConfigLoader: could not read \(url.path): \(error) — no workspaces loaded",
                category: .workspace)
            return []
        }
    }

    private static var warnedPaths: Set<String> = []

    private static func warnAboutMissingDirectories(_ workspaces: [Workspace]) {
        for workspace in workspaces
        where warnedPaths.insert(workspace.path.path).inserted && !PathDisplay.isDirectory(workspace.path) {
            Log.warning(
                "ConfigLoader: workspace `\(workspace.title)` path \(workspace.path.path) isn't a directory",
                category: .workspace)
        }
    }
}
