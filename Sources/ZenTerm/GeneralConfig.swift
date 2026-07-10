import CoreGraphics
import TerminalKit

/// The resolved general configuration for this launch — everything the user can override in
/// `~/.config/zen-term/config`, or the built-in defaults. Loaded once, lazily, launch-only
/// (mirrors `Theme.current`). Reads nothing from `Theme`, so the two lazy `static let`s have
/// a one-way dependency (`Theme.current → GeneralConfig.current`) and never deadlock.
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
        floats: [],
        keymap: KeymapDefaults.map)

    /// The resolved config for this launch, re-resolvable via `reloadCurrent()` when the Settings
    /// card writes the file (see `AppConfig.reload()`). External hand-edits still need a relaunch.
    static private(set) var current: GeneralConfig = ConfigLoader.loadGeneralConfig()

    /// Re-read `config` from disk and swap `current`. Called by `AppConfig.reload()` after a write.
    static func reloadCurrent() { current = ConfigLoader.loadGeneralConfig() }

    /// The subset that crosses the seam to the terminal backends.
    var terminalBehavior: TerminalBehavior {
        TerminalBehavior(
            cursorStyle: cursorStyle, cursorBlink: cursorBlink, cursorThickness: cursorThickness,
            optionAsAlt: optionAsAlt, scrollMultiplier: scrollMultiplier)
    }
}
