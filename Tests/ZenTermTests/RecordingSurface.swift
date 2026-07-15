import AppKit
import TerminalKit

/// A seam-conforming fake for tests that need a `TerminalSurface` without a real
/// backend, recording the config it was started with and whether it was terminated.
final class RecordingSurface: NSObject, TerminalSurface {
    let view = NSView()
    weak var delegate: TerminalSurfaceDelegate?
    var title = ""
    var isFocused = false
    var lastConfig: TerminalSurfaceConfig?
    var terminated = false
    /// When set, `start` reports a creation failure to the delegate instead of "succeeding" —
    /// the seam's dead-surface path (ZEN-100) without needing a real libghostty failure.
    var failOnStart = false
    private(set) var startCount = 0
    func start(_ config: TerminalSurfaceConfig) {
        startCount += 1
        lastConfig = config
        if failOnStart { delegate?.surfaceDidFailToStart(self) }
    }
    func focus() {}
    func terminate() { terminated = true }
    func paste(_ text: String) {}
    func copySelection() -> String? { nil }
    func scrollToBottom() {}
}
