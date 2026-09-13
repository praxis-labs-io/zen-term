import Foundation

struct ConfigChange: OptionSet {
    let rawValue: Int

    static let theme = ConfigChange(rawValue: 1 << 0)

    /// Excludes the drawer fractions: a built tab never re-reads them.
    static let chromeLayout = ConfigChange(rawValue: 1 << 1)

    /// Background alpha is in here and also drives a chrome recolor of the padding ring.
    static let terminalBehavior = ConfigChange(rawValue: 1 << 2)

    static let floats = ConfigChange(rawValue: 1 << 3)

    static let keymap = ConfigChange(rawValue: 1 << 4)

    static let motion = ConfigChange(rawValue: 1 << 5)

    static let diagnostics = ConfigChange(rawValue: 1 << 6)

    static let updates = ConfigChange(rawValue: 1 << 7)

    static let toolbarButtons = ConfigChange(rawValue: 1 << 8)

    static let toasts = ConfigChange(rawValue: 1 << 9)

    static let all: ConfigChange = [
        .theme, .chromeLayout, .terminalBehavior, .floats, .keymap, .motion, .diagnostics, .updates,
        .toolbarButtons, .toasts,
    ]

    static let userInfoKey = "ZenTerm.configChange"

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
        if old.keymap != new.keymap || old.unboundActions != new.unboundActions {
            change.insert(.keymap)
        }
        if old.reduceMotion != new.reduceMotion { change.insert(.motion) }
        if old.configDiagnostics != new.configDiagnostics { change.insert(.diagnostics) }
        if old.automaticUpdateChecks != new.automaticUpdateChecks { change.insert(.updates) }
        if old.hiddenToolbarButtons != new.hiddenToolbarButtons { change.insert(.toolbarButtons) }
        if old.toastDuration != new.toastDuration { change.insert(.toasts) }
        return change
    }

    /// Defaults to `.all`: too much re-apply wastes a frame, too little leaves stale chrome.
    static func from(_ notification: Notification) -> ConfigChange {
        notification.userInfo?[userInfoKey] as? ConfigChange ?? .all
    }
}
