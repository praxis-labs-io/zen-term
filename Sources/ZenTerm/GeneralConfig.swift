import CoreGraphics
import Foundation
import TerminalKit

/// The resolved general configuration — everything the user can override in
/// `~/.config/zen-term/config`, or the built-in defaults. `current` resolves at launch and is
/// re-resolved by `AppConfig.reload()` after an in-app config write (mirrors `Theme.current`).
/// Reads nothing from `Theme`, so the one-way dependency (`Theme.current → GeneralConfig.current`)
/// holds and the two never deadlock.
struct GeneralConfig: Equatable {
    enum ReduceMotion: Equatable { case system, on, off }
    /// Whether a notification card waits to be answered or clears itself after `toastDuration`.
    enum ToastDismissal: Equatable { case sticky, auto }

    // Terminal behavior (crosses the seam into TerminalKit).
    var cursorStyle: TerminalBehavior.CursorStyle
    var cursorBlink: Bool
    var cursorThickness: Int
    var optionAsAlt: Bool
    var fontThicken: Bool
    var scrollMultiplier: Double

    /// The selected cursor shader, as a bundled catalog name in a single `cursor-shader = <name>`
    /// line. `ConfigLoader` resolves the name to a bundled shader's absolute path before it crosses
    /// the seam; an unknown name resolves to nil. Bundled-only, single-select by design.
    var cursorShader: String?

    /// Translucency of the terminal background, 0…1. 1 is a solid surface; below that the pane's
    /// inner padding follows the same value, so the panel reads as one surface (`PanelHostView`).
    var backgroundAlpha: Double

    // Theme — selects a named file from `~/.config/zen-term/themes/`. Nil → the legacy
    // single `theme` file if present, else the built-in default.
    var themeName: String?

    /// Which ANSI slot of the active theme the chrome's `accent` role points at. Nil →
    /// `AccentSlot.themeDefault`. Stored as a slot, not a
    /// color, so it re-resolves against whatever theme is loaded.
    var accentColor: AccentSlot?

    // Font — drives the terminal theme's font (ghostty themes carry no font, so it lives here).
    var fontName: String
    var fontSize: CGFloat

    // Chrome.
    /// Show the standard macOS window buttons (traffic lights) and reserve the header space that
    /// clears them. Off → the fully chromeless top: buttons hidden, an even gutter on
    /// all four sides. Close/minimize still work via ⌘W / ⌘M and the menu.
    var windowChrome: Bool
    var backdropAlpha: CGFloat
    var windowGutter: CGFloat
    var panelGap: CGFloat
    var bottomDrawerFraction: CGFloat
    var rightDrawerFraction: CGFloat
    var drawerResizeStep: CGFloat
    var maxDrawerFraction: CGFloat
    /// The built-in footer-toolbar buttons hidden by `hide-toolbar-buttons`. Visual only: a hidden
    /// button's chord and palette entry stay live.
    var hiddenToolbarButtons: Set<ToolbarButton> = []

    // Motion.
    var reduceMotion: ReduceMotion

    // Notifications — fire a macOS banner when an agent needs attention while the app is unfocused
    // (the macOS permission is the real gate; this is the in-app opt-out).
    var agentNotifications: Bool

    /// The in-app card for a background tab that needs you. Sticky by default: it states a
    /// condition that is still true, so it waits to be answered.
    var attentionToast: ToastDismissal
    /// The in-app card a long command posts when it finishes in a background tab.
    var completionToast: ToastDismissal
    /// Seconds an auto-dismissing toast stays up. Governs every toast that clears itself, not only
    /// the two notification kinds.
    var toastDuration: TimeInterval

    // Updates — check for a new release in the background. On by default; this is the
    // off switch, driving Sparkle's automatic-check setting. Inert in an unpackaged dev build.
    var automaticUpdateChecks: Bool

    // Diagnostics — tee verbose diagnostics to the log file. Off by default; the file
    // otherwise carries only warnings/errors and the key-event trail. `ZENTERM_LOG_VERBOSE=1` is
    // the env equivalent.
    var debug: Bool

    // Launch.
    var shell: String?
    var shellArgs: [String]
    /// Start a new tab or window in the focused pane's working directory instead of home. Off by
    /// default: a tab is a fresh piece of work, where a split is a second view of the one in front
    /// of you, so splits inherit unconditionally and this only governs ⌘T and ⌘N.
    var tabInheritCWD: Bool

    // Workspace preset commands — the editor / AI the "Editor + AI + Shell" preset launches.
    // Nil → the built-in `nvim` / `claude` fallback (see AddWorkspaceOverlay).
    var editor: String?
    var ai: String?

    // Structured.
    var floats: [ToolFloat]
    var keymap: [Chord: KeyInterceptor.ReservedChord]
    /// The actions a `keybind = <action>=none` line asked to leave with no shortcut.
    /// Carried beside `keymap` rather than inferred from it: an action missing from the map is
    /// either this or a collision, and the Shortcuts card has to write the first one back.
    var unboundActions: Set<KeyInterceptor.ReservedChord> = []
    /// Problems found loading the config — a keybind conflict, an invalid scalar, an out-of-range
    /// number, a dropped `float =` line. Each surfaces on the Settings row that owns it (or a Tools
    /// notice / the reload toast for the home-less ones); see `ConfigDiagnostic`.
    var configDiagnostics: [ConfigDiagnostic] = []

    /// The commands the "Editor + AI + Shell" workspace preset falls back to when `editor` / `ai`
    /// are unset — single-sourced here so the Settings placeholders and the preset itself agree.
    static let defaultEditor = "nvim"
    static let defaultAI = "claude"

    /// The historical hardcodes — an absent config file yields exactly this, so behavior is
    /// unchanged from before the file existed. The font literal is single-sourced here; `Theme` reads it.
    static let builtIn = GeneralConfig(
        cursorStyle: .block,
        cursorBlink: true,
        cursorThickness: 2,
        optionAsAlt: true,
        fontThicken: false,
        scrollMultiplier: 1.5,
        cursorShader: nil,
        backgroundAlpha: 1,
        themeName: nil,
        accentColor: nil,
        fontName: "JetBrainsMono Nerd Font Mono",
        fontSize: 14,
        windowChrome: true,
        backdropAlpha: 0.82,
        windowGutter: 8,
        panelGap: 8,
        bottomDrawerFraction: 0.28,
        rightDrawerFraction: 0.30,
        drawerResizeStep: 40,
        maxDrawerFraction: 0.7,
        reduceMotion: .system,
        agentNotifications: true,
        attentionToast: .sticky,
        completionToast: .sticky,
        toastDuration: 4,
        automaticUpdateChecks: true,
        debug: false,
        shell: nil,
        shellArgs: [],
        tabInheritCWD: false,
        editor: nil,
        ai: nil,
        floats: [],
        keymap: KeymapDefaults.map)

    /// The resolved config for this launch, re-resolvable via `reloadCurrent()` when the Settings
    /// card writes the file (see `AppConfig.reload()`). External hand-edits are picked up on
    /// demand via the Reload Config command (⌘⇧,).
    ///
    /// Initialized to the built-in default and resolved from disk by `AppConfig.loadAtLaunch()`
    /// before any window builds. Deliberately *not* `= ConfigLoader.loadGeneralConfig()`: a Swift
    /// static is always lazy, so that default ran a main-thread-only call (see
    /// `ConfigLoader.loadGeneralConfig`) on whichever thread touched it first. Initializing to a
    /// constant makes first touch harmless and puts the load in one named place.
    static private(set) var current: GeneralConfig = .builtIn

    /// Re-read `config` from disk and swap `current`. Called by `AppConfig.reload()` after a write.
    @MainActor
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
            optionAsAlt: optionAsAlt, fontThicken: fontThicken, scrollMultiplier: scrollMultiplier,
            cursorShader: cursorShader, backgroundAlpha: backgroundAlpha)
    }
}
