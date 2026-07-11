import AppKit

/// Applies the `reduce-motion` config knob to `Motion`. `.system` (the default) restores the
/// system-reading closure; `.on`/`.off` force the setting, overriding the OS accessibility
/// preference. Called at launch AND on every `.configDidChange`, so `.system` must actively
/// restore the reader — a prior `.on`/`.off` override has to be undone, not just left in place.
enum MotionConfig {
    static func apply(_ setting: GeneralConfig.ReduceMotion) {
        switch setting {
        case .system: Motion.isReduceMotionEnabled = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
        case .on: Motion.isReduceMotionEnabled = { true }
        case .off: Motion.isReduceMotionEnabled = { false }
        }
    }
}
