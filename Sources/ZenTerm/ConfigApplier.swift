import Foundation

/// The app-global half of the `.configDidChange` fan-out (ZEN-48), lifted out of `AppDelegate` so
/// it can be driven in a test (ZEN-281).
///
/// `AppDelegate` is the `NSApplicationDelegate` singleton: it binds the nav socket and builds
/// windows at launch, and its observer closes over private stored properties. A test could neither
/// stand one up in a known state nor see what the observer block did — and both ZEN-48 regressions
/// lived in exactly that block.
///
/// Every collaborator arrives as a closure so a test can substitute a double. The doubles model
/// *resulting state*, not calls made: the differential test compares where the app lands under the
/// diffed change set against where it lands under `.all`, and "was it called" is the wrong question
/// when re-applying an unchanged value is a no-op.
final class ConfigApplier {
    /// The app-global things a config reload touches. Each reads `GeneralConfig.current` at call
    /// time rather than taking the value, matching how the real observer worked.
    struct Sinks {
        /// Rebuild the key interceptor's chord → action map.
        var setKeymap: ([Chord: KeyInterceptor.ReservedChord]) -> Void
        /// Re-install the reduce-motion override.
        var applyMotion: (GeneralConfig.ReduceMotion) -> Void
        /// Show the config-problems notice, returning whether a window actually took it. `false`
        /// leaves the set un-announced so the next reload retries — see `surfaceConfigDiagnostics`.
        var announceDiagnostics: (ToastContent, ConfigDiagnostic.Scope) -> Bool
        /// Recolor a live update card. Also re-resolves its "Check for Updates" keycap.
        var reapplyUpdateCardTheme: () -> Void
        /// Re-point Sparkle's background check schedule at the config.
        var applyAutoCheckSetting: () -> Void
    }

    private let sinks: Sinks

    /// The config problems announced on the last reload — so an unchanged set stays quiet.
    private var lastAnnouncedDiagnostics: [ConfigDiagnostic] = []

    init(sinks: Sinks) {
        self.sinks = sinks
    }

    /// Re-apply what this reload actually changed. Each block runs only when the config it reads
    /// moved; the dependencies are what the call chain *resolves*, not what the sink is named after.
    ///
    /// **Two entries deliberately do not gate on the kind sharing their name. Don't "tidy" them** —
    /// each comment says why, and both were shipped regressions before they said it.
    func apply(_ change: ConfigChange) {
        if change.contains(.keymap) { sinks.setKeymap(GeneralConfig.current.keymap) }
        if change.contains(.motion) { sinks.applyMotion(GeneralConfig.current.reduceMotion) }
        // Deliberately ungated. This one already has a finer gate than the change set: it tracks
        // what was *delivered*, and leaves `lastAnnouncedDiagnostics` untouched when no window was
        // there to show the notice, so the next reload retries it. Gating on `.diagnostics` would
        // strand an undelivered notice forever — the diagnostics haven't changed, so the retry
        // would never come. The cost is a set comparison that returns nil.
        surfaceConfigDiagnostics()
        // Recolor a live update card — it's outside any window's toast list. Also on `.keymap`:
        // `UpdateCardView.reapplyTheme()` calls `refreshKeycap()`, which re-resolves the
        // "Check for Updates" chord, so a rebind while the card is up has to reach it. Same trap as
        // `reapplyChromeColors` — the name says theme, the call chain reads the keymap.
        if change.contains(.theme) || change.contains(.keymap) { sinks.reapplyUpdateCardTheme() }
        // Pick up a flipped auto-update toggle with no relaunch.
        if change.contains(.updates) { sinks.applyAutoCheckSetting() }
    }

    /// Toast the config's problems when they change (a stolen keybind, an invalid scalar, a dropped
    /// float). App-global rather than per-window: a `WindowController` observer would run once per
    /// open window, so three windows would mean three toasts for one reload. Called on every reload
    /// via `apply(_:)`, and once at launch so a config that's already broken announces itself.
    ///
    /// The announce decision itself is `ConfigDiagnostic.announcement`, where it's pure.
    func surfaceConfigDiagnostics() {
        let diagnostics = GeneralConfig.current.configDiagnostics
        guard
            let content = ConfigDiagnostic.announcement(
                for: diagnostics, alreadyAnnounced: lastAnnouncedDiagnostics)
        else {
            lastAnnouncedDiagnostics = diagnostics
            return
        }
        // Record it as announced only once a window has actually shown it. Delivery fails when the
        // key window isn't one of ours (an open panel), and marking an undelivered notice as
        // announced would let the change-gate swallow it forever. `content` is non-nil only when
        // there's at least one diagnostic, so `first` is the section the toast's button lands on.
        guard let first = diagnostics.first, sinks.announceDiagnostics(content, first.scope) else {
            return
        }
        lastAnnouncedDiagnostics = diagnostics
    }
}
