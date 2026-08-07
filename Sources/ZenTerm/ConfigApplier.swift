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
@MainActor
final class ConfigApplier {
    /// The app-global things a config reload touches. Each reads `GeneralConfig.current` at call
    /// time rather than taking the value, matching how the real observer worked.
    ///
    /// Every closure type is `@MainActor`, and that is load-bearing rather than decorative: a plain
    /// `() -> Void` property erases the isolation of whatever it was built from, so a sink could do
    /// off-main work — including reaching the config parse — and compile clean straight through
    /// this seam (ZEN-31).
    struct Sinks {
        /// Rebuild the key interceptor's chord → action map.
        var setKeymap: @MainActor ([Chord: KeyInterceptor.ReservedChord]) -> Void
        /// Log the chords the new keymap just handed to the backend.
        var reportBackendShadow: @MainActor () -> Void
        /// Re-install the reduce-motion override.
        var applyMotion: @MainActor (GeneralConfig.ReduceMotion) -> Void
        /// Show the config-problems notice, returning whether a window actually took it. `false`
        /// leaves the set un-announced so the next reload retries — see `surfaceConfigDiagnostics`.
        var announceDiagnostics: @MainActor (ToastContent, ConfigDiagnostic.Scope) -> Bool
        /// Take down an outstanding config-problems notice. A no-op when none is showing.
        var retractDiagnostics: @MainActor () -> Void
        /// Show one card per outstanding chord conflict, returning whether a window took them.
        /// Separate from `announceDiagnostics` because each card carries its own two answers.
        var announceConflicts: @MainActor ([KeybindConflict]) -> Bool
        /// Take down every outstanding conflict card. A no-op when none are showing.
        var retractConflicts: @MainActor () -> Void
        /// Recolor a live update card. Also re-resolves its "Check for Updates" keycap.
        var reapplyUpdateCardTheme: @MainActor () -> Void
        /// Re-point Sparkle's background check schedule at the config.
        var applyAutoCheckSetting: @MainActor () -> Void
    }

    private let sinks: Sinks

    /// The config problems announced on the last reload — so an unchanged set stays quiet.
    private var lastAnnouncedDiagnostics: [ConfigDiagnostic] = []

    /// The conflicts carded on the last reload, gating re-announcement the same way. Every in-app
    /// write reloads, so without this a Settings rebind would put three dismissed cards back.
    /// Across launches it is a fresh process, which is what makes an unanswered conflict return.
    private var lastAnnouncedConflicts: [KeybindConflict] = []

    init(sinks: Sinks) {
        self.sinks = sinks
    }

    /// Re-apply what this reload actually changed. Each block runs only when the config it reads
    /// moved; the dependencies are what the call chain *resolves*, not what the sink is named after.
    ///
    /// **Two entries deliberately do not gate on the kind sharing their name. Don't "tidy" them** —
    /// each comment says why, and both were shipped regressions before they said it.
    func apply(_ change: ConfigChange) {
        if change.contains(.keymap) {
            sinks.setKeymap(GeneralConfig.current.keymap)
            // A rebind frees the action's old chord, and what libghostty does with it is a question
            // only a live surface can answer. Re-asked on every keymap change rather than cached:
            // the backend answers against its config as it stands now.
            sinks.reportBackendShadow()
        }
        if change.contains(.motion) { sinks.applyMotion(GeneralConfig.current.reduceMotion) }
        // Deliberately ungated. This one already has a finer gate than the change set: it tracks
        // what was *delivered*, and leaves `lastAnnouncedDiagnostics` untouched when no window was
        // there to show the notice, so the next reload retries it. Gating on `.diagnostics` would
        // strand an undelivered notice forever — the diagnostics haven't changed, so the retry
        // would never come. The cost is a set comparison that returns nil.
        surfaceConfigNotices()
        // Recolor a live update card — it's outside any window's toast list. Also on `.keymap`:
        // `UpdateCardView.reapplyTheme()` calls `refreshKeycap()`, which re-resolves the
        // "Check for Updates" chord, so a rebind while the card is up has to reach it. Same trap as
        // `reapplyChromeColors` — the name says theme, the call chain reads the keymap.
        if change.contains(.theme) || change.contains(.keymap) { sinks.reapplyUpdateCardTheme() }
        // Pick up a flipped auto-update toggle with no relaunch.
        if change.contains(.updates) { sinks.applyAutoCheckSetting() }
    }

    /// Everything the config says out loud: the shared problems notice, and a card per chord
    /// conflict. **The only entry point, and both halves below are private because of that.**
    ///
    /// Launch does not go through `apply(_:)`; it calls this directly, so a second surface added
    /// beside the first and wired only into `apply` is announced on reload and silent at launch.
    /// That shipped once: three conflicts, no cards, because launch called the half by name
    /// (ZEN-368). One public method is what makes calling half of it impossible rather than merely
    /// unlikely.
    func surfaceConfigNotices() {
        surfaceConfigDiagnostics()
        surfaceConflicts()
    }

    /// Toast the config's problems when they change (a stolen keybind, an invalid scalar, a dropped
    /// float). App-global rather than per-window: a `WindowController` observer would run once per
    /// open window, so three windows would mean three toasts for one reload. Called on every reload
    /// via `apply(_:)`, and once at launch so a config that's already broken announces itself.
    ///
    /// The announce decision itself is `ConfigDiagnostic.announcement`, where it's pure.
    ///
    /// The notice is sticky, and it states what is wrong **now** rather than logging what happened
    /// at some past reload. So it is retracted as well as raised: fixing the config and reloading
    /// takes it down, and a changed set replaces it rather than stacking a second card beside one
    /// that describes different problems.
    private func surfaceConfigDiagnostics() {
        // Chord conflicts are announced one card each, by `surfaceConflicts`. What's left shares a
        // notice, because none of it has anything to press (ZEN-368).
        let diagnostics = GeneralConfig.current.configDiagnostics.filter { !$0.isChordConflict }
        guard !diagnostics.isEmpty else {
            // Nothing is wrong any more. `announcement` returns nil for an empty set, so before
            // this the stale warning simply outlived the fix that made it false.
            if !lastAnnouncedDiagnostics.isEmpty { sinks.retractDiagnostics() }
            lastAnnouncedDiagnostics = []
            return
        }
        guard
            let content = ConfigDiagnostic.announcement(
                for: diagnostics, alreadyAnnounced: lastAnnouncedDiagnostics),
            let first = diagnostics.first
        else { return }  // unchanged set: the notice already up is still accurate, so stay quiet
        // No retraction here, deliberately. `announceDiagnostics` replaces any notice already up as
        // part of delivering the new one, so the swap is all-or-nothing. Retracting first and
        // announcing second would take an accurate notice down and then fail to put its replacement
        // back whenever delivery fails, leaving a broken config with an empty screen.
        //
        // Record it as announced only once a window has actually shown it. Delivery fails when the
        // key window isn't one of ours (an open panel), and marking an undelivered notice as
        // announced would let the change-gate swallow it forever.
        guard sinks.announceDiagnostics(content, first.scope) else { return }
        lastAnnouncedDiagnostics = diagnostics
    }

    /// Card every chord conflict the config is reporting, one each (ZEN-368).
    ///
    /// Retracted as well as raised, for the reason the shared notice is: the cards state what is
    /// true now, so answering one in Settings or fixing the file by hand has to take its card down.
    private func surfaceConflicts() {
        let conflicts = KeybindConflict.all(in: GeneralConfig.current)
        guard !conflicts.isEmpty else {
            if !lastAnnouncedConflicts.isEmpty { sinks.retractConflicts() }
            lastAnnouncedConflicts = []
            return
        }
        guard conflicts != lastAnnouncedConflicts else { return }  // same set: the cards up are right
        guard sinks.announceConflicts(conflicts) else { return }
        lastAnnouncedConflicts = conflicts
    }
}
