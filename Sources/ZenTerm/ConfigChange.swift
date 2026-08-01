import Foundation

/// What actually changed across a config reload, so a `.configDidChange` observer can skip the
/// work its own surface doesn't depend on. A keybind rebind is the motivating case: it used to
/// pay a full chrome re-apply (relayout every tab, recolor every surface, rebuild the dock) for a
/// change nothing in the chrome layout reads.
///
/// Carried in the notification's `userInfo` under `ConfigChange.userInfoKey`. **An absent or
/// unreadable value means "assume everything changed"** — `ConfigChange.from(_:)` returns `.all`
/// — so a hand-posted notification (tests, any future caller that doesn't diff) keeps the old
/// do-everything behavior rather than silently skipping a re-apply.
struct ConfigChange: OptionSet {
    let rawValue: Int

    /// `Theme.current` moved: the terminal palette/font handed to surfaces, or any chrome role
    /// derived from it. Subsumes `theme`, `font-family` and `font-size`, since all three resolve
    /// into the `AppTheme` rather than being read on their own.
    static let theme = ConfigChange(rawValue: 1 << 0)

    /// A chrome metric the built views are laid out against: `window-chrome`, `backdrop-alpha`,
    /// `window-gutter`, `pane-gap`. The drawer fractions are deliberately excluded — a built tab
    /// never re-reads them (a hand ⌥-resize owns the running ratio; they seed new tabs only), so
    /// changing one has no live work to do.
    static let chromeLayout = ConfigChange(rawValue: 1 << 1)

    /// The `TerminalBehavior` handed across the seam: cursor style/blink/thickness, option-as-alt,
    /// scroll multiplier, cursor shader, background alpha. The last one also reaches chrome —
    /// `PanelHostView` fills its padding ring to match — so it drives a recolor too (ZEN-282).
    static let terminalBehavior = ConfigChange(rawValue: 1 << 2)

    /// The tool-float catalog: a float added, edited, or removed.
    static let floats = ConfigChange(rawValue: 1 << 3)

    /// The chord → command map. Reaches further than the interceptor: anything that renders a
    /// keycap resolves its glyph from the live keymap.
    static let keymap = ConfigChange(rawValue: 1 << 4)

    /// The `reduce-motion` preference.
    static let motion = ConfigChange(rawValue: 1 << 5)

    /// The problems found loading the config, which surface on the Settings rows that own them.
    static let diagnostics = ConfigChange(rawValue: 1 << 6)

    /// The `automatic-update-checks` toggle, driving Sparkle's background check.
    static let updates = ConfigChange(rawValue: 1 << 7)

    /// The `hide-toolbar-buttons` set: which built-in footer-toolbar buttons are hidden.
    static let toolbarButtons = ConfigChange(rawValue: 1 << 8)

    static let all: ConfigChange = [
        .theme, .chromeLayout, .terminalBehavior, .floats, .keymap, .motion, .diagnostics, .updates,
        .toolbarButtons,
    ]

    static let userInfoKey = "ZenTerm.configChange"

    /// Diff two resolved configs into the set of kinds that moved.
    static func between(
        old: GeneralConfig, new: GeneralConfig, oldTheme: AppTheme, newTheme: AppTheme
    ) -> ConfigChange {
        var change: ConfigChange = []
        if oldTheme != newTheme { change.insert(.theme) }
        if old.windowChrome != new.windowChrome || old.backdropAlpha != new.backdropAlpha
            || old.windowGutter != new.windowGutter || old.panelGap != new.panelGap
        {
            change.insert(.chromeLayout)
        }
        if old.terminalBehavior != new.terminalBehavior { change.insert(.terminalBehavior) }
        if old.floats != new.floats { change.insert(.floats) }
        if old.keymap != new.keymap { change.insert(.keymap) }
        if old.reduceMotion != new.reduceMotion { change.insert(.motion) }
        if old.configDiagnostics != new.configDiagnostics { change.insert(.diagnostics) }
        if old.automaticUpdateChecks != new.automaticUpdateChecks { change.insert(.updates) }
        if old.hiddenToolbarButtons != new.hiddenToolbarButtons { change.insert(.toolbarButtons) }
        return change
    }

    /// Read the change set off a `.configDidChange` notification, defaulting to `.all` when the
    /// poster didn't carry one. The default is the safe direction: too much re-apply is a wasted
    /// frame, too little is stale chrome.
    static func from(_ notification: Notification) -> ConfigChange {
        notification.userInfo?[userInfoKey] as? ConfigChange ?? .all
    }
}
