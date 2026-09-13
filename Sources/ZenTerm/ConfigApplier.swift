import Foundation

@MainActor
final class ConfigApplier {
    /// `@MainActor` closure types, because a plain closure erases isolation and lets off-main work compile.
    struct Sinks {
        var setKeymap: @MainActor ([Chord: KeyInterceptor.ReservedChord]) -> Void
        var reportBackendShadow: @MainActor () -> Void
        var applyMotion: @MainActor (GeneralConfig.ReduceMotion) -> Void
        var announceDiagnostics: @MainActor (ToastContent, ConfigDiagnostic.Scope) -> Bool
        var retractDiagnostics: @MainActor () -> Void
        var announceConflicts: @MainActor ([KeybindConflict]) -> Bool
        var retractConflicts: @MainActor () -> Void
        var reapplyUpdateCardTheme: @MainActor () -> Void
        var applyAutoCheckSetting: @MainActor () -> Void
        var publishTheme: @MainActor () -> Void
    }

    private let sinks: Sinks

    private var lastAnnouncedDiagnostics: [ConfigDiagnostic] = []

    /// Every in-app write reloads, so without this gate a Settings rebind would re-card dismissed conflicts.
    private var lastAnnouncedConflicts: [KeybindConflict] = []

    init(sinks: Sinks) {
        self.sinks = sinks
    }

    /// Notices run ungated to retry an undelivered one.
    func apply(_ change: ConfigChange) {
        if change.contains(.keymap) {
            sinks.setKeymap(GeneralConfig.current.keymap)
            sinks.reportBackendShadow()
        }
        if change.contains(.motion) { sinks.applyMotion(GeneralConfig.current.reduceMotion) }
        surfaceConfigNotices()
        if change.contains(.theme) || change.contains(.keymap) { sinks.reapplyUpdateCardTheme() }
        if change.contains(.updates) { sinks.applyAutoCheckSetting() }
        if change.contains(.theme) { sinks.publishTheme() }
    }

    /// The only entry point, so launch cannot announce half of what a reload does.
    func surfaceConfigNotices() {
        surfaceConfigDiagnostics()
        surfaceConflicts()
    }

    private func surfaceConfigDiagnostics() {
        let diagnostics = GeneralConfig.current.configDiagnostics.filter { !$0.isChordConflict }
        guard !diagnostics.isEmpty else {
            if !lastAnnouncedDiagnostics.isEmpty { sinks.retractDiagnostics() }
            lastAnnouncedDiagnostics = []
            return
        }
        guard
            let content = ConfigDiagnostic.announcement(
                for: diagnostics, alreadyAnnounced: lastAnnouncedDiagnostics),
            let first = diagnostics.first
        else { return }
        guard sinks.announceDiagnostics(content, first.scope) else { return }
        lastAnnouncedDiagnostics = diagnostics
    }

    private func surfaceConflicts() {
        let conflicts = KeybindConflict.all(in: GeneralConfig.current)
        guard !conflicts.isEmpty else {
            if !lastAnnouncedConflicts.isEmpty { sinks.retractConflicts() }
            lastAnnouncedConflicts = []
            return
        }
        guard conflicts != lastAnnouncedConflicts else { return }
        guard sinks.announceConflicts(conflicts) else { return }
        lastAnnouncedConflicts = conflicts
    }
}
