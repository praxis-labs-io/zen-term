import Foundation

extension Notification.Name {
    /// Posted after `AppConfig.reload()` re-resolves the config statics, so living consumers
    /// (the keymap now; chrome layout and terminal surfaces in later PRs) re-apply.
    static let configDidChange = Notification.Name("ZenTerm.configDidChange")
}

/// The save→reload→apply seam. After the Settings card writes `config` via `ConfigWriter`,
/// `reload()` re-resolves the launch statics from disk (general first, then theme, which reads
/// the general font) and broadcasts `configDidChange`. The invariant: after any write + reload,
/// `GeneralConfig.current` / `Theme.current` mirror the file.
enum AppConfig {
    static func reload() {
        GeneralConfig.reloadCurrent()
        Theme.reloadCurrent()
        NotificationCenter.default.post(name: .configDidChange, object: nil)
    }
}
