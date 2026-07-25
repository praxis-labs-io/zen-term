import Foundation

extension Notification.Name {
    /// Posted after `AppConfig.reload()` re-resolves the config statics, so living consumers
    /// (the keymap now; chrome layout and terminal surfaces in later PRs) re-apply.
    ///
    /// Carries a `ConfigChange` in `userInfo` naming what actually moved, so an observer can skip
    /// the work its surface doesn't depend on. A notification posted without one reads as `.all`.
    static let configDidChange = Notification.Name("ZenTerm.configDidChange")
}

/// The save→reload→apply seam. After the Settings card writes `config` via `ConfigWriter`,
/// `reload()` re-resolves the launch statics from disk (general first, then theme, which reads
/// the general font) and broadcasts `configDidChange`. The invariant: after any write + reload,
/// `GeneralConfig.current` / `Theme.current` mirror the file.
enum AppConfig {
    static func reload() {
        // Snapshot before re-resolving so the broadcast can name what moved. Settings live-apply
        // is debounced at 180 ms, so a slider drag posts ~5 times a second and every observer that
        // re-applies unconditionally pays for it — see `ConfigChange`.
        let oldConfig = GeneralConfig.current
        let oldTheme = Theme.current
        GeneralConfig.reloadCurrent()
        Theme.reloadCurrent()
        let change = ConfigChange.between(
            old: oldConfig, new: GeneralConfig.current, oldTheme: oldTheme, newTheme: Theme.current)
        NotificationCenter.default.post(
            name: .configDidChange, object: nil, userInfo: [ConfigChange.userInfoKey: change])
    }
}
