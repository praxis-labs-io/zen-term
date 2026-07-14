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
    func start(_ config: TerminalSurfaceConfig) { lastConfig = config }
    func focus() {}
    func terminate() { terminated = true }
    func paste(_ text: String) {}
    func copySelection() -> String? { nil }
    func scrollToBottom() {}
}
