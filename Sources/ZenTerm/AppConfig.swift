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
    /// Resolve the launch statics from disk, once, before any window builds. Separate from
    /// `reload()` because there is nothing to diff and no observer to broadcast to yet.
    @MainActor
    static func loadAtLaunch() {
        GeneralConfig.reloadCurrent()
        Theme.reloadCurrent()
        // Seed the session font size before any surface spawns, so the first pane opens at the
        // config's size rather than the built-in default.
        SessionFontSize.seed(from: GeneralConfig.current)
    }

    /// - Parameter force: broadcast `.all` instead of the diff, so every observer re-applies even
    ///   when the file resolved to the same values. This is what ⌘⇧, (Reload Config) passes: it's
    ///   the user's "make the app match my config" escape hatch, and a manual keystroke can afford
    ///   the full re-apply that a 5-per-second field edit cannot.
    @MainActor
    static func reload(force: Bool = false) {
        // Snapshot before re-resolving so the broadcast can name what moved. Settings live-apply
        // is debounced at 180 ms, so typing in a numeric field posts ~5 times a second and every observer that
        // re-applies unconditionally pays for it — see `ConfigChange`.
        let oldConfig = GeneralConfig.current
        let oldTheme = Theme.current
        GeneralConfig.reloadCurrent()
        Theme.reloadCurrent()
        // Before the broadcast, not in an observer: `.configDidChange` observers run in registration
        // order, so a window that re-applied first would push the pre-reload size and leave its
        // surfaces stale. Only a moved `font-size` re-seeds — a color or font-family edit leaves a
        // size the user stepped exactly where they put it.
        SessionFontSize.reseedIfBaseChanged(from: GeneralConfig.current)
        let change =
            force
            ? .all
            : ConfigChange.between(
                old: oldConfig, new: GeneralConfig.current, oldTheme: oldTheme,
                newTheme: Theme.current)
        NotificationCenter.default.post(
            name: .configDidChange, object: nil, userInfo: [ConfigChange.userInfoKey: change])
    }
}
