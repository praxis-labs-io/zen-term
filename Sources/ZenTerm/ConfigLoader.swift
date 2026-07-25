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
        makeAppTheme(themeText: readThemeText(configRoot: configRoot, general: general), general: general)
    }

    /// Locate and read the active theme file. **Filesystem work, safe off the main thread** — this
    /// is the half `AppConfig` runs on its queue (ZEN-17). nil means "use the built-in": no theme
    /// file, a named theme that doesn't exist, or one that wouldn't read.
    static func readThemeText(configRoot: URL = defaultRoot, general: GeneralConfig) -> String? {
        guard let themeURL = resolveThemeURL(configRoot: configRoot, general: general) else { return nil }
        do {
            return try String(contentsOf: themeURL, encoding: .utf8)
        } catch {
            Log.warning(
                "ConfigLoader: could not read \(themeURL.path): \(error) — using built-in theme",
                category: .config)
            return nil
        }
    }

    /// Build the theme from text already read. Pure: no filesystem, so the caller decides where the
    /// I/O happened. `AppConfig` runs this on main, next to the general-config parse it pairs with.
    static func makeAppTheme(themeText: String?, general: GeneralConfig) -> AppTheme {
        let builtIn = Theme.rosePineMoon
        var terminal =
            themeText.map {
                GhosttyThemeParser.parse(
                    $0, fontName: builtIn.fontName, fontSize: builtIn.fontSize, fallback: builtIn)
            } ?? builtIn

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
        parseGeneralConfig(readGeneralConfigText(configRoot: configRoot))
    }

    /// Read the `config` file. **Filesystem work, safe off the main thread** — the half `AppConfig`
    /// runs on its queue (ZEN-17). nil means "use the built-in": absent, or unreadable.
    static func readGeneralConfigText(configRoot: URL = defaultRoot) -> String? {
        let configURL = configRoot.appendingPathComponent("config")
        guard FileManager.default.fileExists(atPath: configURL.path) else { return nil }
        do {
            return try String(contentsOf: configURL, encoding: .utf8)
        } catch {
            Log.warning(
                "ConfigLoader: could not read \(configURL.path): \(error) — using built-in config",
                category: .config)
            return nil
        }
    }

    /// Parse text already read. **Main thread only, and not for a reason you'd guess:** the parse
    /// assembles the keymap, which asks the keyboard layout what a chord can type, which calls
    /// Carbon `TISCopyCurrentKeyboardLayoutInputSource`. TIS is main-thread-only in a GUI app and
    /// takes the process down from a background queue — silently, with no crash report, and with a
    /// green `swift test` (TIS answers fine off-main there). See `AppConfig` (ZEN-17).
    static func parseGeneralConfig(_ text: String?) -> GeneralConfig {
        // Not a defensive guard: off main this kills the process with no crash report and no failing
        // test, which is how it shipped once. Trap here so the next person who moves config work
        // onto a queue is told where, instead of hunting a silent quit.
        dispatchPrecondition(condition: .onQueue(.main))
        guard let text else { return .builtIn }
        var config = GeneralConfigParser.parse(text, fallback: .builtIn)
        config.cursorShader = resolveShader(config.cursorShader)
        return config
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

    /// Load the hand-curated `workspaces` file (the `⌘⇧P` picker) from the config root, off the
    /// main thread, and deliver the result on it.
    ///
    /// This is what every caller uses. The read is one small file, but `~/.config` can sit on a
    /// network-backed or cloud-synced home directory, and the chrome never blocks the main queue on
    /// a filesystem answer (ZEN-90), so the card that renders from this is built when the list
    /// lands rather than presented empty and filled (ZEN-275).
    static func loadWorkspaces(configRoot: URL = defaultRoot, completion: @escaping ([Workspace]) -> Void) {
        loadQueue.async {
            let workspaces = loadWorkspaces(configRoot: configRoot)
            DispatchQueue.main.async { completion(workspaces) }
            // Hand the list over BEFORE validating it, and on another queue: the caller is a card
            // waiting to be built, and the validation is one `stat` per workspace, unbounded on a
            // network share. Running it here would gate the card on it, and running it on the load
            // queue would leave a hung mount blocking the next load behind it.
            validationQueue.async { warnAboutMissingDirectories(workspaces) }
        }
    }

    /// Serial: two windows opening their pickers at once read the same file, so there's nothing to
    /// gain from overlapping them, and serializing keeps the reads predictable.
    private static let loadQueue = DispatchQueue(label: "com.zenterm.config-load", qos: .userInitiated)

    /// Serial too, and separate from the load queue: it's the only thread that touches
    /// `warnedPaths`, so the set needs no lock, and an unbounded `stat` here can't hold up a load.
    private static let validationQueue = DispatchQueue(
        label: "com.zenterm.config-validate", qos: .utility)

    /// Read and parse the `workspaces` file. Absent or unreadable → an empty list; the parser drops
    /// any malformed section rather than throw.
    ///
    /// This is the parse step behind the completion-handler form above, which is what every caller
    /// uses; it is separate only so the read can be driven from the load queue and from tests. It
    /// blocks and it does not validate paths, so calling it directly from the main thread is the
    /// ZEN-90 stall this whole path exists to remove.
    static func loadWorkspaces(configRoot: URL = defaultRoot) -> [Workspace] {
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

    /// Warn about a workspace whose `path` doesn't resolve to a directory, once per path per run, so
    /// a typo surfaces instead of silently opening a shell at a bad cwd. The workspace is still kept
    /// — the directory may appear later.
    ///
    /// Diagnostic only, and one `stat` per workspace, so it runs on its own queue after the list has
    /// already been handed over: nothing waits on it. Every ⌘⇧P open reloads the file, so warning on each pass would
    /// reprint the same line for the life of the process; the seen set keeps the first one, which is
    /// the one that tells the user about the typo.
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
