import AppKit
import TerminalKit

/// A seam-conforming fake for tests that need a `TerminalSurface` without a real
/// backend, recording the config it was started with and whether it was terminated.
final class RecordingSurface: NSObject, TerminalSurface {
    let view = NSView()
    weak var delegate: TerminalSurfaceDelegate?
    var title = ""
    /// Driven by `focus()`, so a test can assert who the chrome actually handed focus to (matching
    /// the seam's own fake in `SeamTests`). Nothing un-focuses a surface through the protocol —
    /// the chrome focuses the one that should hold it — so there's no clear path to model.
    private(set) var isFocused = false
    var lastConfig: TerminalSurfaceConfig?
    /// Overrides the protocol extension's nil default so a test can drive cwd drift — the same
    /// property `PaneCanvasController.focusedCWD` prefers over its last OSC-reported value.
    var currentDirectory: URL?
    /// Overrides the protocol extension's false default so a test can mark a surface as having
    /// live work — what the ⌘W confirm reads through `hasBusyToolFloat`/`hasBusyDrawer`.
    var isBusy = false
    var terminated = false
    /// When set, `start` reports a creation failure to the delegate instead of succeeding, which
    /// exercises the seam's dead-surface path (ZEN-100) without needing a real libghostty failure.
    var failOnStart = false
    private(set) var startCount = 0
    func start(_ config: TerminalSurfaceConfig) {
        startCount += 1
        lastConfig = config
        if let theme = config.theme, let behavior = config.behavior {
            lastAppearance = (theme, behavior)
        }
        // Mirror the real backend's async delivery (see `TerminalSurfaceDelegate`) so tests
        // exercise the same timing: the failure arrives after the caller has wired us up.
        if failOnStart {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.surfaceDidFailToStart(self)
            }
        }
    }
    /// The appearance this surface is currently wearing: what it was **started** with, then
    /// whatever `applyAppearance` last pushed. The protocol's default `applyAppearance` is a no-op,
    /// so without this a stub records nothing and the `.configDidChange` fan-out's reach into live
    /// surfaces is invisible to a test (ZEN-281).
    ///
    /// Seeded from `start` deliberately. A real surface is already wearing its launch appearance,
    /// so a stub that starts blank would report a difference between a reload that re-pushed the
    /// same values and one that skipped the push — which is a difference the user cannot see.
    private(set) var lastAppearance: (theme: TerminalTheme, behavior: TerminalBehavior)?
    func applyAppearance(theme: TerminalTheme, behavior: TerminalBehavior) {
        lastAppearance = (theme, behavior)
    }
    func focus() { isFocused = true }
    func terminate() { terminated = true }
    /// Records paste text so a test can assert a ⌘V was (or was not) routed into a surface — the
    /// discriminator for "did the modal card swallow paste, or did it fall through to the terminal".
    private(set) var pastes: [String] = []
    func paste(_ text: String) { pastes.append(text) }
    func copySelection() -> String? { nil }
    func scrollToBottom() {}
}
