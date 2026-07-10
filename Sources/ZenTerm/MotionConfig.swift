import AppKit

/// Applies the `reduce-motion` config knob to `Motion` at launch. `.system` (the default)
/// leaves `Motion`'s system-reading closure untouched; `.on`/`.off` force the setting,
/// overriding the OS accessibility preference. Called once, early, from `AppDelegate`.
enum MotionConfig {
    static func apply(_ setting: GeneralConfig.ReduceMotion) {
        switch setting {
        case .system: break
        case .on: Motion.isReduceMotionEnabled = { true }
        case .off: Motion.isReduceMotionEnabled = { false }
        }
    }
}
