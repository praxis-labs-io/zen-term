import CoreGraphics
import Foundation
import TerminalKit

/// Reads nothing from `Theme`, so the dependency on it stays one-way.
struct GeneralConfig: Equatable {
    enum ReduceMotion: Equatable { case system, on, off }
    enum ToastDismissal: Equatable { case sticky, auto }

    var cursorStyle: TerminalBehavior.CursorStyle
    var cursorBlink: Bool
    var cursorThickness: Int
    var optionAsAlt: Bool
    var fontThicken: Bool
    var scrollMultiplier: Double

    var cursorShader: String?

    var backgroundAlpha: Double

    /// Nil falls back to the legacy single `theme` file, then the built-in default.
    var themeName: String?

    var accentColor: AccentSlot?

    /// Lives here because ghostty themes carry no font.
    var fontName: String
    var fontSize: CGFloat

    var windowChrome: Bool
    var backdropAlpha: CGFloat
    var windowGutter: CGFloat
    var panelGap: CGFloat
    var bottomDrawerFraction: CGFloat
    var rightDrawerFraction: CGFloat
    var drawerResizeStep: CGFloat
    var maxDrawerFraction: CGFloat
    /// Visual only: a hidden button's shortcut and palette entry stay live.
    var hiddenToolbarButtons: Set<ToolbarButton> = []

    var reduceMotion: ReduceMotion

    var agentNotifications: Bool

    var attentionToast: ToastDismissal
    var completionToast: ToastDismissal
    var toastDuration: TimeInterval

    /// Inert in an unpackaged dev build.
    var automaticUpdateChecks: Bool

    /// `ZENTERM_LOG_VERBOSE=1` is the environment equivalent.
    var debug: Bool

    var shell: String?
    var shellArgs: [String]
    /// Governs ⌘T and ⌘N only; a pane split always inherits.
    var tabInheritCWD: Bool

    var editor: String?
    var ai: String?

    var floats: [ToolFloat]
    var keymap: [Chord: KeyInterceptor.ReservedChord]
    /// Carried beside `keymap`: an action missing from it is either unbound or a collision.
    var unboundActions: Set<KeyInterceptor.ReservedChord> = []
    var configDiagnostics: [ConfigDiagnostic] = []

    static let defaultEditor = "nvim"
    static let defaultAI = "claude"

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

    /// Starts at `builtIn` because a lazy loading default would run a main-thread-only call on any thread.
    static private(set) var current: GeneralConfig = .builtIn

    @MainActor
    static func reloadCurrent() { current = ConfigLoader.loadGeneralConfig() }

    #if DEBUG
        static func setCurrentForTesting(_ config: GeneralConfig) { current = config }
    #endif

    var terminalBehavior: TerminalBehavior {
        TerminalBehavior(
            cursorStyle: cursorStyle, cursorBlink: cursorBlink, cursorThickness: cursorThickness,
            optionAsAlt: optionAsAlt, fontThicken: fontThicken, scrollMultiplier: scrollMultiplier,
            cursorShader: cursorShader, backgroundAlpha: backgroundAlpha)
    }
}
