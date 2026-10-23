import AppKit

enum MotionConfig {
    /// `.system` actively restores the reader, since a reload must undo an earlier override.
    static func apply(_ setting: GeneralConfig.ReduceMotion) {
        switch setting {
        case .system: Motion.isReduceMotionEnabled = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
        case .on: Motion.isReduceMotionEnabled = { true }
        case .off: Motion.isReduceMotionEnabled = { false }
        }
    }
}
