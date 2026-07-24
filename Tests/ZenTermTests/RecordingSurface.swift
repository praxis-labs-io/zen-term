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
        // Mirror the real backend's async delivery (see `TerminalSurfaceDelegate`) so tests
        // exercise the same timing: the failure arrives after the caller has wired us up.
        if failOnStart {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.surfaceDidFailToStart(self)
            }
        }
    }
    /// Counts `focus()` calls so a test can tell "was focused now" from the sticky `isFocused` (which,
    /// like the real protocol, is never cleared through the seam) — the discriminator for whether a
    /// send actually moved focus to its target.
    private(set) var focusCount = 0
    func focus() {
        isFocused = true
        focusCount += 1
    }
    func terminate() { terminated = true }
    /// Records paste text so a test can assert a ⌘V was (or was not) routed into a surface — the
    /// discriminator for "did the modal card swallow paste, or did it fall through to the terminal".
    private(set) var pastes: [String] = []
    func paste(_ text: String) { pastes.append(text) }
    func copySelection() -> String? { nil }
    func scrollToBottom() {}
    /// Records a real Return keypress separately from pastes, so a test can assert submit went through
    /// the key path (a real Enter) rather than a bracketed `"\r"` paste that a TUI wouldn't act on.
    private(set) var submitCount = 0
    func submitLine() { submitCount += 1 }
}
