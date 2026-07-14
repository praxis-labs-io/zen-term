import CoreGraphics
import TerminalKit

/// The resolved general configuration — everything the user can override in
/// `~/.config/zen-term/config`, or the built-in defaults. `current` resolves at launch and is
/// re-resolved by `AppConfig.reload()` after an in-app config write (mirrors `Theme.current`).
/// Reads nothing from `Theme`, so the one-way dependency (`Theme.current → GeneralConfig.current`)
/// holds and the two never deadlock.
struct GeneralConfig: Equatable {
    enum ReduceMotion: Equatable { case system, on, off }

    // Terminal behavior (crosses the seam into TerminalKit).
    var cursorStyle: TerminalBehavior.CursorStyle
    var cursorBlink: Bool
    var cursorThickness: Int
    var optionAsAlt: Bool
    var scrollMultiplier: Double

    // Theme — selects a named file from `~/.config/zen-term/themes/`. Nil → the legacy
    // single `theme` file if present, else the built-in default.
    var themeName: String?

    // Font — drives the terminal theme's font (ghostty themes carry no font, so it lives here).
    var fontName: String
    var fontSize: CGFloat

    // Chrome.
    var backdropAlpha: CGFloat
    var windowGutter: CGFloat
    var panelGap: CGFloat
    var bottomDrawerFraction: CGFloat
    var rightDrawerFraction: CGFloat
    var drawerResizeStep: CGFloat
    var maxDrawerFraction: CGFloat

    // Motion.
    var reduceMotion: ReduceMotion

    // Launch.
    var shell: String?
    var shellArgs: [String]

    // Workspace preset commands — the editor / AI the "Editor + AI + Shell" preset launches.
    // Nil → the built-in `nvim` / `claude` fallback (see AddWorkspaceOverlay).
    var editor: String?
    var ai: String?

    // Structured.
    var floats: [ToolFloat]
    var keymap: [Chord: KeyInterceptor.ReservedChord]

    /// The historical hardcodes — an absent config file yields exactly this, so behavior is
    /// unchanged from before ZEN-71. The font literal is single-sourced here; `Theme` reads it.
    static let builtIn = GeneralConfig(
        cursorStyle: .block,
        cursorBlink: true,
        cursorThickness: 2,
        optionAsAlt: true,
        scrollMultiplier: 1.5,
        themeName: nil,
        fontName: "JetBrainsMono Nerd Font Mono",
        fontSize: 14,
        backdropAlpha: 0.82,
        windowGutter: 8,
        panelGap: 8,
        bottomDrawerFraction: 0.28,
        rightDrawerFraction: 0.30,
        drawerResizeStep: 40,
        maxDrawerFraction: 0.7,
        reduceMotion: .system,
        shell: nil,
        shellArgs: [],
        editor: nil,
        ai: nil,
        floats: [],
        keymap: KeymapDefaults.map)

    /// The resolved config for this launch, re-resolvable via `reloadCurrent()` when the Settings
    /// card writes the file (see `AppConfig.reload()`). External hand-edits are picked up on
    /// demand via the Reload Config command (⌘⌥R).
    static private(set) var current: GeneralConfig = ConfigLoader.loadGeneralConfig()

    /// Re-read `config` from disk and swap `current`. Called by `AppConfig.reload()` after a write.
    static func reloadCurrent() { current = ConfigLoader.loadGeneralConfig() }

    #if DEBUG
        /// Test hook: swap `current` directly so a test can drive config-reactive code (e.g.
        /// `ShellLaunch`'s custom-shell branch) without a file write. `current`'s setter is otherwise
        /// `private`, and `reloadCurrent()` only re-reads real config off disk. Mirrors
        /// `Theme.setCurrentForTesting`; pair with a teardown that restores the original.
        static func setCurrentForTesting(_ config: GeneralConfig) { current = config }
    #endif

    /// The subset that crosses the seam to the terminal backends.
    var terminalBehavior: TerminalBehavior {
        TerminalBehavior(
            cursorStyle: cursorStyle, cursorBlink: cursorBlink, cursorThickness: cursorThickness,
            optionAsAlt: optionAsAlt, scrollMultiplier: scrollMultiplier)
    }
}
